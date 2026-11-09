<#
.SYNOPSIS
    Creates or updates the Entra app registration that fronts portal sign-in, configuring
    everything EasyAuth + role-based access needs. Idempotent — safe to re-run against an
    existing app registration / enterprise app (e.g. one created by another provisioning process).

.DESCRIPTION
    Configures, in one pass:
      - Web redirect URI for the portal (`https://<portal>/.auth/login/aad/callback`) + ID tokens
      - Application ID URI `api://<clientId>` and the `user_impersonation` delegated scope
      - Pre-authorization of the app to call its own API (no consent prompt)
      - v2 access tokens (the API's EasyAuth validates against the v2 issuer)
      - The `Governance.Admin` and `Governance.Member` app roles (existing role IDs are
        preserved per value, so user/group assignments survive a re-run)
      - The enterprise application's "Assignment required = Yes"
      - Optionally the federated identity credential for the portal's managed identity (no secret)
    Optionally creates a client secret and writes it to the portal Web App (client-secret mode).

    Existing configuration is MERGED, not replaced: other redirect URIs, identifier URIs,
    scopes, pre-authorized apps, app roles, the logout URL and known client applications
    are kept. Graph rejects removing an enabled scope or role, so the script never drops them.

.PARAMETER PortalHostname
    The host name users open the portal on: the Front Door host when published
    (e.g. `identity.contoso.com`), otherwise the default `<app>.azurewebsites.net` host.

.PARAMETER DisplayName
    App registration display name. Used to create a new app, or to locate one when
    -ApplicationId is omitted.

.PARAMETER ApplicationId
    (Optional) Existing app registration's Application (client) ID to update. If omitted,
    the script finds one by DisplayName, or creates a new registration.

.PARAMETER ManagedIdentityPrincipalId
    (Optional) Principal (object) ID of the portal's user-assigned identity
    (`id-<appName>-portal-<env>`, Bicep output portalIdentityPrincipalId). When given, the
    federated identity credential EasyAuth uses instead of a client secret is created if missing.

.PARAMETER FederatedCredentialName
    (Optional) Name of the federated identity credential. Default `easyauth-portal`.

.PARAMETER AdminGroupName
.PARAMETER MemberGroupName
    (Optional) Display names of Entra security groups for the Governance.Admin and
    Governance.Member roles, e.g. `IdentityGovernance-Admins`. Each group is created if missing
    (security group, not mail-enabled) and assigned to its role on the enterprise application.
    Add people to the groups afterwards. Only direct members get access (nested groups are
    not supported) and group assignment requires Entra ID P1/P2.

.PARAMETER CreateSecret
    (Optional switch) Create a new client secret and print it. Not for use with
    -ManagedIdentityPrincipalId.

.PARAMETER PortalAppName
.PARAMETER ResourceGroupName
    (Optional) When both are supplied together with -CreateSecret, the new secret is written
    to the portal Web App as MICROSOFT_PROVIDER_AUTHENTICATION_SECRET via the Azure CLI.

.EXAMPLE
    # dev: client secret, default host
    .\Configure-AuthAppRegistration.ps1 -PortalHostname "<WebAppName>.azurewebsites.net" -CreateSecret

.EXAMPLE
    # prd: existing registration, Front Door host, managed identity instead of a secret
    $principalId = az identity show -g <RG> -n id-<App>-portal-prd --query principalId -o tsv
    .\Configure-AuthAppRegistration.ps1 -PortalHostname "identity.contoso.com" -ApplicationId "<clientId>" -ManagedIdentityPrincipalId $principalId -WhatIf

.NOTES
    Requires the Microsoft.Graph module and the Application.ReadWrite.All scope.
    Required Entra role: Application Administrator (or higher), or owner of the app registration
    (owners can't set Assignment required on the enterprise application without a role).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$PortalHostname,
    [string]$DisplayName = "Identity Governance Portal",
    [string]$ApplicationId,
    [string]$ManagedIdentityPrincipalId,
    [string]$FederatedCredentialName = "easyauth-portal",
    [string]$AdminGroupName,
    [string]$MemberGroupName,
    [switch]$CreateSecret,
    [string]$PortalAppName,
    [string]$ResourceGroupName
)

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Configure Auth App Registration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($CreateSecret -and $ManagedIdentityPrincipalId) {
    Write-Host "[ERROR] -CreateSecret and -ManagedIdentityPrincipalId are mutually exclusive: the managed identity replaces the secret." -ForegroundColor Red
    exit 1
}
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    Write-Host "[ERROR] Microsoft.Graph module not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser" -ForegroundColor Red
    exit 1
}
$graphScopes = @("Application.ReadWrite.All")
if ($AdminGroupName -or $MemberGroupName) { $graphScopes += @("Group.ReadWrite.All", "AppRoleAssignment.ReadWrite.All") }
$ctx = Get-MgContext
$missingScopes = @($graphScopes | Where-Object { $ctx -and $ctx.Scopes -notcontains $_ })
if (-not $ctx -or $missingScopes.Count -gt 0) { Connect-MgGraph -Scopes $graphScopes | Out-Null }

$PortalHostname = $PortalHostname.Trim().TrimEnd('/') -replace '^https?://', ''
$redirectUri = "https://$PortalHostname/.auth/login/aad/callback"

# ── Find or create the app registration ──
$app = $null
if ($ApplicationId) {
    $app = Get-MgApplication -Filter "appId eq '$ApplicationId'" -ErrorAction SilentlyContinue
    if (-not $app) { Write-Host "[ERROR] No app registration with appId '$ApplicationId'." -ForegroundColor Red; exit 1 }
} else {
    $app = Get-MgApplication -Filter "displayName eq '$DisplayName'" -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $app) {
    if (-not $PSCmdlet.ShouldProcess($DisplayName, "Create app registration")) {
        Write-Host "[WhatIf] Would create app registration '$DisplayName' and configure it. Nothing else to preview." -ForegroundColor Gray
        return
    }
    $app = New-MgApplication -DisplayName $DisplayName -SignInAudience "AzureADMyOrg"
    Write-Host "Created app registration '$DisplayName' (appId $($app.AppId))" -ForegroundColor Green
} else {
    Write-Host "Updating existing app registration '$($app.DisplayName)' (appId $($app.AppId))" -ForegroundColor Yellow
    if ($app.SignInAudience -ne 'AzureADMyOrg') {
        Write-Host "[WARN] Sign-in audience is '$($app.SignInAudience)', expected 'AzureADMyOrg' (single tenant). Not changed." -ForegroundColor Yellow
    }
}
$clientId = $app.AppId
$identifierUri = "api://$clientId"

# ── Identifier URIs (merge; EasyAuth on the API accepts the api://<clientId> audience) ──
$identifierUris = @($app.IdentifierUris | Where-Object { $_ })
if ($identifierUris -notcontains $identifierUri) { $identifierUris += $identifierUri }

# ── Scopes: update user_impersonation (reuse its Id), keep every other scope as-is ──
function ConvertTo-ScopeHash { param($s)
    @{ Id = $s.Id; Value = $s.Value; Type = $s.Type; IsEnabled = $s.IsEnabled
       AdminConsentDisplayName = $s.AdminConsentDisplayName; AdminConsentDescription = $s.AdminConsentDescription
       UserConsentDisplayName = $s.UserConsentDisplayName; UserConsentDescription = $s.UserConsentDescription }
}
$existingScopes = @($app.Api.Oauth2PermissionScopes | Where-Object { $_ })
$existingScope = $existingScopes | Where-Object { $_.Value -eq 'user_impersonation' } | Select-Object -First 1
$scopeId = if ($existingScope) { $existingScope.Id } else { [guid]::NewGuid().ToString() }
$scope = @{
    Id                      = $scopeId
    Value                   = "user_impersonation"
    Type                    = "User"
    IsEnabled               = $true
    AdminConsentDisplayName = "Access the Identity Governance Portal API"
    AdminConsentDescription = "Allow the app to access the Identity Governance Portal API on behalf of the signed-in user."
    UserConsentDisplayName  = "Access the Identity Governance Portal API"
    UserConsentDescription  = "Allow the app to access the API on your behalf."
}
$allScopes = @(@($existingScopes | Where-Object { $_.Value -ne 'user_impersonation' } | ForEach-Object { ConvertTo-ScopeHash $_ }) + $scope)

# ── Pre-authorized apps: ensure the app itself has user_impersonation, keep the others ──
$preAuth = @($app.Api.PreAuthorizedApplications | Where-Object { $_ -and $_.AppId -ne $clientId } | ForEach-Object {
        @{ AppId = $_.AppId; DelegatedPermissionIds = @($_.DelegatedPermissionIds) }
    })
$selfPreAuth = $app.Api.PreAuthorizedApplications | Where-Object { $_.AppId -eq $clientId } | Select-Object -First 1
$selfPermissionIds = @(@($selfPreAuth.DelegatedPermissionIds | Where-Object { $_ }) + $scopeId | Select-Object -Unique)
$preAuth += @{ AppId = $clientId; DelegatedPermissionIds = $selfPermissionIds }

# `api` is replaced as a whole on PATCH, so resend the properties we don't manage.
$apiBase = @{
    RequestedAccessTokenVersion = 2
    KnownClientApplications     = @($app.Api.KnownClientApplications | Where-Object { $_ })
}
if ($null -ne $app.Api.AcceptMappedClaims) { $apiBase.AcceptMappedClaims = $app.Api.AcceptMappedClaims }

# ── App roles (reuse existing Id per value so assignments survive re-runs) ──
function New-GovRole { param([string]$Value, [string]$Display, [string]$Desc)
    $existing = $app.AppRoles | Where-Object { $_.Value -eq $Value } | Select-Object -First 1
    $id = if ($existing) { $existing.Id } else { [guid]::NewGuid().ToString() }
    # Keep member types the role already has (e.g. Application) — narrowing an enabled role is rejected.
    $types = @(@($existing.AllowedMemberTypes | Where-Object { $_ }) + "User" | Select-Object -Unique)
    return @{ Id = $id; AllowedMemberTypes = $types; Value = $Value; DisplayName = $Display; Description = $Desc; IsEnabled = $true }
}
$govRoles = @(
    (New-GovRole "Governance.Admin"  "Governance Admin"  "Full access to all identities, the dashboard, and all governance actions."),
    (New-GovRole "Governance.Member" "Governance Member" "Access to the app registrations and enterprise apps the user owns, with owner self-service actions.")
)
# Preserve any unrelated app roles the registration may already have (e.g. a default role).
$otherRoles = @($app.AppRoles | Where-Object { $_ -and $_.Value -notin @('Governance.Admin', 'Governance.Member') } | ForEach-Object {
        @{ Id = $_.Id; AllowedMemberTypes = $_.AllowedMemberTypes; Value = $_.Value; DisplayName = $_.DisplayName; Description = $_.Description; IsEnabled = $_.IsEnabled }
    })
$allRoles = @($otherRoles + $govRoles)

# ── Web platform: merge the redirect URI, keep the logout URL ──
$redirects = @($app.Web.RedirectUris | Where-Object { $_ })
if ($redirects -notcontains $redirectUri) { $redirects += $redirectUri }
# ID tokens ON (EasyAuth hybrid flow `code id_token`), implicit access tokens OFF.
$web = @{ RedirectUris = $redirects; ImplicitGrantSettings = @{ EnableIdTokenIssuance = $true; EnableAccessTokenIssuance = $false } }
if ($app.Web.LogoutUrl) { $web.LogoutUrl = $app.Web.LogoutUrl }

$staleRedirects = @($redirects | Where-Object { $_ -ne $redirectUri -and $_ -like '*.azurewebsites.net/*' })
if ($staleRedirects.Count -gt 0) {
    Write-Host "[INFO] Other azurewebsites.net redirect URIs are kept: $($staleRedirects -join ', '). Remove them by hand if that host is no longer used." -ForegroundColor Gray
}

# ── Apply ──
# Two-step update: a scope (oauth2PermissionScopes) must already be persisted on the
# application before preAuthorizedApplications can reference it. Sending both in one
# PATCH fails with "Permission Id ... cannot be found in the AppPermissions sets", so
# create the scope first, then add the self pre-authorization that points at it.
# RequestedAccessTokenVersion = 2 makes this API issue v2 access tokens (issuer
# https://login.microsoftonline.com/<tenant>/v2.0). The Function App's EasyAuth is
# configured with that v2 issuer, so v1 tokens (the default) would be rejected as 401.
if ($PSCmdlet.ShouldProcess("$($app.DisplayName) ($clientId)", "Set redirect URI $redirectUri, identifier URI $identifierUri, user_impersonation scope, v2 tokens and Governance.Admin/Member roles")) {
    $api1 = $apiBase.Clone()
    $api1.Oauth2PermissionScopes = $allScopes
    # Keep existing pre-authorizations that don't reference user_impersonation yet (it may be new).
    $api1.PreAuthorizedApplications = @($preAuth | Where-Object { $_.AppId -ne $clientId })
    Update-MgApplication -ApplicationId $app.Id `
        -IdentifierUris $identifierUris `
        -Web $web `
        -Api $api1 `
        -AppRoles $allRoles

    # Now that the scope exists, pre-authorize the portal app to call its own API.
    # Oauth2PermissionScopes is resent so the PATCH to `api` doesn't drop the scopes.
    $api2 = $apiBase.Clone()
    $api2.Oauth2PermissionScopes = $allScopes
    $api2.PreAuthorizedApplications = $preAuth
    Update-MgApplication -ApplicationId $app.Id -Api $api2

    Write-Host "[OK] Redirect URI, $identifierUri scope, self pre-authorization, v2 tokens and Governance.Admin/Member roles configured." -ForegroundColor Green
}

# ── Enterprise application (service principal): require assignment ──
$sp = Get-MgServicePrincipal -Filter "appId eq '$clientId'" -ErrorAction SilentlyContinue
if (-not $sp) {
    if ($PSCmdlet.ShouldProcess($clientId, "Create enterprise application (service principal)")) {
        $sp = New-MgServicePrincipal -AppId $clientId
        Write-Host "Created enterprise application (service principal)." -ForegroundColor Green
    }
}
if ($sp -and -not $sp.AppRoleAssignmentRequired) {
    if ($PSCmdlet.ShouldProcess($sp.DisplayName, "Set Assignment required = Yes")) {
        Update-MgServicePrincipal -ServicePrincipalId $sp.Id -AppRoleAssignmentRequired:$true
    }
}
if ($sp) { Write-Host "[OK] Enterprise application: Assignment required = Yes." -ForegroundColor Green }

# ── Role groups: create if missing and assign to the app roles ──
$roleGroups = @(@(
    @{ Name = $AdminGroupName;  Role = $govRoles[0] }
    @{ Name = $MemberGroupName; Role = $govRoles[1] }
) | Where-Object { $_.Name })
if ($roleGroups -and -not $sp) {
    Write-Host "[WhatIf] Groups are assigned once the enterprise application exists." -ForegroundColor Gray
    $roleGroups = @()
}
$existingAssignments = if ($roleGroups) { @(Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -All) } else { @() }
foreach ($rg in $roleGroups) {
    $groupName = $rg.Name
    $roleValue = $rg.Role.Value
    $groups = @(Get-MgGroup -Filter "displayName eq '$($groupName -replace "'", "''")'" -ConsistencyLevel eventual -CountVariable groupCount)
    if ($groups.Count -gt 1) {
        Write-Host "[ERROR] $($groups.Count) groups are named '$groupName'. Rename or remove the duplicates, then re-run." -ForegroundColor Red
        exit 1
    }
    $group = $groups | Select-Object -First 1
    if ($group -and -not $group.SecurityEnabled) {
        Write-Host "[ERROR] Group '$groupName' exists but is not a security group; it can't be used for app role assignment." -ForegroundColor Red
        exit 1
    }
    if (-not $group) {
        if (-not $PSCmdlet.ShouldProcess($groupName, "Create security group")) { continue }
        $nickname = ($groupName -replace '[^A-Za-z0-9_-]', '')
        $group = New-MgGroup -DisplayName $groupName -MailEnabled:$false -MailNickname $nickname -SecurityEnabled `
            -Description "Members get the $roleValue role in $($app.DisplayName). Direct members only (nested groups are not supported)."
        Write-Host "[OK] Created security group '$groupName' ($($group.Id))." -ForegroundColor Green
    }

    if ($existingAssignments | Where-Object { $_.PrincipalId -eq $group.Id -and $_.AppRoleId -eq $rg.Role.Id }) {
        Write-Host "[OK] '$groupName' already has $roleValue." -ForegroundColor Green
        continue
    }
    if (-not $PSCmdlet.ShouldProcess("$groupName -> $roleValue", "Assign group to app role")) { continue }
    # A new group can take a few seconds to replicate before it can be assigned.
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -BodyParameter @{
                PrincipalId = $group.Id; ResourceId = $sp.Id; AppRoleId = $rg.Role.Id
            } | Out-Null
            Write-Host "[OK] Assigned '$groupName' to $roleValue." -ForegroundColor Green
            break
        } catch {
            if ($attempt -eq 6) { throw }
            Write-Host "  Waiting for '$groupName' to replicate (attempt $attempt)..." -ForegroundColor Gray
            Start-Sleep -Seconds 10
        }
    }
}

# ── Federated identity credential for the portal's managed identity (no secret) ──
if ($ManagedIdentityPrincipalId) {
    $issuer = "https://login.microsoftonline.com/$((Get-MgContext).TenantId)/v2.0"
    $fics = @(Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -All)
    $match = $fics | Where-Object { $_.Issuer -eq $issuer -and $_.Subject -eq $ManagedIdentityPrincipalId } | Select-Object -First 1
    if ($match) {
        Write-Host "[OK] Federated credential '$($match.Name)' for $ManagedIdentityPrincipalId already exists." -ForegroundColor Green
    } elseif ($fics | Where-Object { $_.Name -eq $FederatedCredentialName }) {
        Write-Host "[ERROR] A federated credential named '$FederatedCredentialName' exists with another issuer/subject. Pass -FederatedCredentialName or fix it by hand." -ForegroundColor Red
        exit 1
    } elseif ($fics.Count -ge 20) {
        Write-Host "[ERROR] The app registration already has 20 federated credentials (the maximum)." -ForegroundColor Red
        exit 1
    } elseif ($PSCmdlet.ShouldProcess("$($app.DisplayName) ($clientId)", "Add federated credential '$FederatedCredentialName' (subject $ManagedIdentityPrincipalId)")) {
        New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter @{
            Name        = $FederatedCredentialName
            Issuer      = $issuer
            Subject     = $ManagedIdentityPrincipalId
            Audiences   = @("api://AzureADTokenExchange")
            Description = "EasyAuth on the portal signs in with its user-assigned managed identity instead of a client secret."
        } | Out-Null
        Write-Host "[OK] Federated credential '$FederatedCredentialName' added for $ManagedIdentityPrincipalId." -ForegroundColor Green
    }

    $secrets = @($app.PasswordCredentials | Where-Object { $_ })
    if ($secrets.Count -gt 0) {
        Write-Host "[WARN] The app registration still has $($secrets.Count) client secret(s): $(($secrets | ForEach-Object { "'$($_.DisplayName)' (expires $($_.EndDateTime))" }) -join ', ')." -ForegroundColor Yellow
        Write-Host "       Once sign-in works with the managed identity, remove them: Certificates & secrets -> Client secrets." -ForegroundColor Yellow
    }
}

# ── Optional client secret ──
if ($CreateSecret -and $PSCmdlet.ShouldProcess("$($app.DisplayName) ($clientId)", "Create client secret")) {
    $pwd = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential @{ DisplayName = "EasyAuth secret"; EndDateTime = (Get-Date).AddYears(1) }
    Write-Host ""
    Write-Host "Client secret (shown once — store it securely):" -ForegroundColor Yellow
    Write-Host "  $($pwd.SecretText)" -ForegroundColor Yellow
    if ($PortalAppName -and $ResourceGroupName) {
        az webapp config appsettings set -g $ResourceGroupName -n $PortalAppName --settings "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET=$($pwd.SecretText)" | Out-Null
        Write-Host "[OK] Wrote it to '$PortalAppName' as MICROSOFT_PROVIDER_AUTHENTICATION_SECRET." -ForegroundColor Green
    } else {
        Write-Host "  Set it on the portal Web App:" -ForegroundColor Yellow
        Write-Host "    az webapp config appsettings set -g <rg> -n <portal-app> --settings MICROSOFT_PROVIDER_AUTHENTICATION_SECRET=<value>" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Done. Application (client) ID: $clientId" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Next:" -ForegroundColor Yellow
Write-Host "  1. Put this client ID in azuredeploy.parameters.<env>.json -> authClientId, then re-run deploy.ps1." -ForegroundColor Gray
if ($roleGroups) {
    Write-Host "  2. Add people (direct members) to: $(($roleGroups | ForEach-Object { $_.Name }) -join ', '). Only assigned users can sign in." -ForegroundColor Gray
} else {
    Write-Host "  2. Entra ID -> Enterprise applications -> this app -> Users and groups: assign users/groups to" -ForegroundColor Gray
    Write-Host "     'Governance Admin' or 'Governance Member' (or re-run with -AdminGroupName/-MemberGroupName). Only assigned users can sign in." -ForegroundColor Gray
}
