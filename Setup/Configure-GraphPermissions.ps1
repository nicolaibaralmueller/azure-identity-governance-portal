<#
.SYNOPSIS
    Grants Microsoft Graph API permissions to the Function App managed identity.

.DESCRIPTION
    Phase 2 - Step 1 of 3 (Manual, requires privileged operator)
    
    Assigns Graph API application roles directly to the Function App's
    system-assigned managed identity. No App Registration needed.

.PARAMETER ResourceGroupName
    Resource group where the Function App is deployed.

.PARAMETER FunctionAppName
    Name of the Function App (API), e.g. "<App>-api-dev".

.PARAMETER WebAppName
    Name of the Web App (portal), e.g. "<App>-portal-dev".
    Used by the validation script (Step 3).

.EXAMPLE
    .\Configure-GraphPermissions.ps1 -ResourceGroupName "<RG>" -FunctionAppName "<FunctionAppName>" -WebAppName "<WebAppName>"

.NOTES
    Required Entra ID Role: Privileged Role Administrator or Global Administrator
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $true)]
    [string]$WebAppName
)

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Step 1: Configure Graph Permissions" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Prerequisites Check
# ============================================================================

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    Write-Host "[ERROR] Microsoft.Graph module not found. Install with:" -ForegroundColor Red
    Write-Host "  Install-Module Microsoft.Graph -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}

# Connect to Graph if not already connected
$context = Get-MgContext
if (-not $context) {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
    Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All", "Application.Read.All"
    $context = Get-MgContext
}
Write-Host "Connected as: $($context.Account)" -ForegroundColor Green

# ============================================================================
# Discover Function App Managed Identity
# ============================================================================

Write-Host ""
Write-Host "Looking up Function App: $FunctionAppName" -ForegroundColor Yellow

$functionApp = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction SilentlyContinue
if (-not $functionApp) {
    Write-Host "[ERROR] Function App '$FunctionAppName' not found in resource group '$ResourceGroupName'" -ForegroundColor Red
    Write-Host "Ensure the infrastructure deploy (Phase 1, deploy.ps1) has completed successfully." -ForegroundColor Yellow
    exit 1
}

$managedIdentityId = $functionApp.Identity.PrincipalId
if (-not $managedIdentityId) {
    Write-Host "[ERROR] Function App does not have a system-assigned managed identity" -ForegroundColor Red
    exit 1
}

Write-Host "Managed Identity Principal ID: $managedIdentityId" -ForegroundColor Green

# Wait for the managed identity's service principal to replicate into Entra. On a
# freshly deployed app it can take a minute or two; assigning roles before it exists
# fails with ResourceNotFound. Poll up to ~2 minutes.
$miSp = $null
for ($i = 1; $i -le 12; $i++) {
    $miSp = Get-MgServicePrincipal -ServicePrincipalId $managedIdentityId -ErrorAction SilentlyContinue
    if ($miSp) { break }
    Write-Host "  Waiting for managed identity to propagate in Entra... ($i/12)" -ForegroundColor Gray
    Start-Sleep -Seconds 10
}
if (-not $miSp) {
    Write-Host "[ERROR] Managed identity service principal '$managedIdentityId' not visible in Entra after ~2 minutes. Wait a few minutes and re-run." -ForegroundColor Red
    exit 1
}

# ============================================================================
# Define Required Graph API Permissions
# ============================================================================
# Microsoft Graph Service Principal App ID: 00000003-0000-0000-c000-000000000000
#
# These are APPLICATION permissions assigned directly to the managed identity.
# No App Registration or delegated permissions needed.
#
# Adjust these to match YOUR solution's requirements.
# ============================================================================

$graphAppId = "00000003-0000-0000-c000-000000000000"

$requiredPermissions = @(
    @{ Name = "Application.Read.All";    Id = "9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30" }
    @{ Name = "Directory.Read.All";      Id = "7ab1d382-f21e-4acd-a863-ba3e13f7da61" }
    @{ Name = "GroupMember.Read.All";     Id = "98830695-27a2-44f7-8c18-0c3ebc9698f6" }
    @{ Name = "User.Read.All";           Id = "df021288-bdef-4463-88db-98f22de89214" }
    # Policy.Read.All — required by SyncTenantConfig-Timer (consent health card:
    # authorizationPolicy + adminConsentRequestPolicy) and by SyncIdentityCache-Timer
    # (Conditional Access coverage / CAStatus column).
    @{ Name = "Policy.Read.All";         Id = "246dd0d5-5bd0-4def-940b-0421030a5b68" }
    # AuditLog.Read.All — required by SyncIdentityCache-Timer for service-principal
    # sign-in activity (Last Sign-in column / stale-identity detection).
    @{ Name = "AuditLog.Read.All";       Id = "b0afded3-3588-46d8-8b3d-9842eff778da" }
)

# ============================================================================
# Display Permission Summary
# ============================================================================

Write-Host ""
Write-Host "The following Graph API permissions will be granted to the Function App MI:" -ForegroundColor Yellow
Write-Host ""
foreach ($perm in $requiredPermissions) {
    Write-Host "  - $($perm.Name)" -ForegroundColor White
}
Write-Host ""

$confirm = Read-Host "Proceed? (y/n)"
if ($confirm -ne 'y') {
    Write-Host "Aborted." -ForegroundColor Red
    exit 0
}

# ============================================================================
# Grant Graph API App Roles to Managed Identity
# ============================================================================

$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
if (-not $graphSp) {
    Write-Host "[ERROR] Microsoft Graph service principal not found" -ForegroundColor Red
    exit 1
}

Write-Host ""

$currentAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentityId -All
$failed = 0

foreach ($perm in $requiredPermissions) {
    # Check if already assigned
    $existing = $currentAssignments | Where-Object { $_.AppRoleId -eq $perm.Id }

    if ($existing) {
        Write-Host "[SKIP] $($perm.Name) — already granted" -ForegroundColor Yellow
        continue
    }
    try {
        New-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $managedIdentityId `
            -PrincipalId $managedIdentityId `
            -ResourceId $graphSp.Id `
            -AppRoleId $perm.Id -ErrorAction Stop | Out-Null

        Write-Host "[OK]   $($perm.Name) — granted" -ForegroundColor Green
    } catch {
        # A duplicate assignment is success, not failure — treat it as already granted.
        if ("$($_.Exception.Message)" -match 'already exist|Permission being assigned already exists') {
            Write-Host "[SKIP] $($perm.Name) — already granted" -ForegroundColor Yellow
        } else {
            Write-Host "[FAIL] $($perm.Name) — $($_.Exception.Message)" -ForegroundColor Red
            $failed++
        }
    }
}

# ============================================================================
# Save Context for Subsequent Scripts
# ============================================================================

$setupContext = @{
    ResourceGroupName     = $ResourceGroupName
    FunctionAppName       = $FunctionAppName
    WebAppName            = $WebAppName
    ManagedIdentityId     = $managedIdentityId
    GraphPermissionsSet   = ($failed -eq 0)
}

$contextPath = Join-Path $PSScriptRoot "_setup-context.json"
$setupContext | ConvertTo-Json | Set-Content -Path $contextPath

if ($failed -gt 0) {
    Write-Host ""
    Write-Host "[ERROR] $failed Graph permission(s) could not be granted. Re-run after a few minutes (managed-identity propagation), or verify you have the Privileged Role Administrator role." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Graph API permissions configured" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next: Run 'Assign-DirectoryRoles.ps1'" -ForegroundColor Yellow