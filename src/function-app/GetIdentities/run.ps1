using namespace System.Net
param($Request, $TriggerMetadata)

$type = $Request.Query.type
if ($type -notin @("appregistration", "enterpriseapp", "managedidentity", "privilegeduser")) { $type = "appregistration" }

# ── Authorization ──
# Members may only view their OWN app registrations / enterprise apps. Managed identities
# and privileged users are admin-only. Unrecognised callers are denied (defense in depth).
$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = '{"error":"No governance role assigned."}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}
if ($caller.IsMember -and $type -in @("managedidentity", "privilegeduser")) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = '{"error":"Members cannot view this identity type."}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}

$storageToken = (Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://storage.azure.com/&api-version=2019-08-01" -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token
$tableBaseUri = $env:AzureWebJobsStorage__tableServiceUri
if (-not $tableBaseUri.EndsWith("/")) { $tableBaseUri += "/" }

function Get-TableEntities { param([string]$TableName, [string]$Filter)
    $enc = [System.Uri]::EscapeDataString($Filter); $uri = "${tableBaseUri}${TableName}()?`$filter=$enc&`$top=1000"; $all = @()
    do { $h = @{ Authorization = "Bearer $storageToken"; Accept = "application/json;odata=nometadata"; "x-ms-version" = "2020-12-06"; "x-ms-date" = (Get-Date).ToUniversalTime().ToString("R") }
        $resp = Invoke-WebRequest -Method GET -Uri $uri -Headers $h; $parsed = $resp.Content | ConvertFrom-Json; $all += $parsed.value
        $np = $resp.Headers["x-ms-continuation-NextPartitionKey"]; if ($np -is [array]) { $np = $np[0] }; $nr = $resp.Headers["x-ms-continuation-NextRowKey"]; if ($nr -is [array]) { $nr = $nr[0] }
        if (-not [string]::IsNullOrWhiteSpace($np)) { $uri = "${tableBaseUri}${TableName}()?`$filter=$enc&`$top=1000&NextPartitionKey=$np"; if (-not [string]::IsNullOrWhiteSpace($nr)) { $uri += "&NextRowKey=$nr" } } else { $uri = $null }
    } while ($uri); return $all }

function Get-AllTableEntities { param([string]$TableName)
    $uri = "${tableBaseUri}${TableName}()?`$top=1000"; $all = @()
    do { $h = @{ Authorization = "Bearer $storageToken"; Accept = "application/json;odata=nometadata"; "x-ms-version" = "2020-12-06"; "x-ms-date" = (Get-Date).ToUniversalTime().ToString("R") }
        $resp = Invoke-WebRequest -Method GET -Uri $uri -Headers $h; $parsed = $resp.Content | ConvertFrom-Json; $all += $parsed.value
        $np = $resp.Headers["x-ms-continuation-NextPartitionKey"]; if ($np -is [array]) { $np = $np[0] }; $nr = $resp.Headers["x-ms-continuation-NextRowKey"]; if ($nr -is [array]) { $nr = $nr[0] }
        if (-not [string]::IsNullOrWhiteSpace($np)) { $uri = "${tableBaseUri}${TableName}()?`$top=1000&NextPartitionKey=$np"; if (-not [string]::IsNullOrWhiteSpace($nr)) { $uri += "&NextRowKey=$nr" } } else { $uri = $null }
    } while ($uri); return $all }

$highRiskRoles = @("Global Administrator", "Privileged Role Administrator", "Exchange Administrator", "SharePoint Administrator", "Application Administrator", "Cloud Application Administrator", "Privileged Authentication Administrator", "Authentication Administrator", "Security Administrator", "User Administrator", "Intune Administrator", "Compliance Administrator")
$highRiskPerms = @("ReadWrite.All", "FullControl.All", "Mail.ReadWrite", "Mail.Send", "Files.ReadWrite.All", "Sites.FullControl.All", "Directory.ReadWrite.All", "RoleManagement.ReadWrite.Directory", "AppRoleAssignment.ReadWrite.All", "Application.ReadWrite.All", "User.ReadWrite.All", "Group.ReadWrite.All")
$medRiskPerms  = @("Read.All", "User.Read.All", "Mail.Read", "Files.Read.All", "Sites.Read.All", "Directory.Read.All", "AuditLog.Read.All", "Group.Read.All")

# Enterprise apps: optionally exclude/include Microsoft first-party service principals
# server-side. The default portal load excludes them (a tenant can have hundreds), and
# they are lazy-loaded only when the user switches "Hide Microsoft" off.
#   firstParty=exclude  -> only non-first-party (IsFirstParty eq 'false')
#   firstParty=only     -> only first-party     (IsFirstParty eq 'true')
$firstParty  = $Request.Query.firstParty
$cacheFilter = "PartitionKey eq '$type'"
if ($type -eq 'enterpriseapp') {
    if     ($firstParty -eq 'exclude') { $cacheFilter += " and IsFirstParty eq 'false'" }
    elseif ($firstParty -eq 'only')    { $cacheFilter += " and IsFirstParty eq 'true'" }
}
$cacheEntities = Get-TableEntities -TableName "IdentityCache" -Filter $cacheFilter

# ── Governance state from GovernanceState table ──
$govEntities = Get-AllTableEntities -TableName "GovernanceState"
$tagLookup = @{}
foreach ($t in $govEntities) { $tagLookup[$t.RowKey] = $t }

$now = Get-Date

# ── Fast path: overlay LIVE governance onto a precomputed ShapedJson object ──
# The sync timers store the fully-shaped identity (owners, credential status, classified
# roles/perms, risk) so this runs no per-request parsing, classification or risk scoring —
# only the cheap governance merge (deletion tags, rename requests, notify opt-in, pending
# owner changes) that changes between syncs.
function Set-Governance { param($o, $tag, $pendingReqs)
    if ($tag) {
        $o.MarkedForDeletion = ($tag.MarkedForDeletion -eq "true")
        $o.MarkedBy          = $tag.MarkedBy
        $o.MarkedOn          = $tag.MarkedOn
        $o.ProposedName      = $tag.ProposedName
        $o.RenameRequestedBy = $tag.RenameRequestedBy
        $o.RenameRequestedOn = $tag.RenameRequestedOn
        $o.NotifyOnExpiry    = ($tag.NotifyOnExpiry -eq "true")
        $o.ContextPurpose     = $tag.ContextPurpose
        $o.ContextSystem      = $tag.ContextSystem
        $o.ContextEnvironment = $tag.ContextEnvironment
        $o.ContextCriticality = $tag.ContextCriticality
        $o.ContextUpdatedBy   = $tag.ContextUpdatedBy
        $o.ContextUpdatedOn   = $tag.ContextUpdatedOn
    }
    $o.PendingOwnerChanges = $pendingReqs
    return $o
}

# ── PRIVILEGED USERS ──
if ($type -eq "privilegeduser") {
    $result = $cacheEntities | ForEach-Object {
        if ($_.ShapedJson) {
            $o = $_.ShapedJson | ConvertFrom-Json
            return (Set-Governance -o $o -tag $tagLookup[$_.RowKey] -pendingReqs @())
        }
        $roles = if ($_.RolesJson -and $_.RolesJson -ne '[]') { try { ,@($_.RolesJson | ConvertFrom-Json) } catch { ,@() } } else { ,@() }

        $classifiedRoles = $roles | ForEach-Object {
            $lvl = if ($_.PSObject.Properties['RiskLevel'] -and $_.RiskLevel) { $_.RiskLevel } elseif ($highRiskRoles -contains $_.RoleName) { "High" } else { "Medium" }
            [PSCustomObject]@{ RoleName = $_.RoleName; RiskLevel = $lvl }
        }

        $tag = $tagLookup[$_.RowKey]

        $lastSignIn      = if ($_.LastSignInDate -and $_.LastSignInDate -ne "") { $_.LastSignInDate } else { $null }
        $daysSinceSignIn = if ($lastSignIn) { try { [math]::Floor(($now - [datetime]$lastSignIn).TotalDays) } catch { $null } } else { $null }

        $risks = @()
        $hasHighRole = ($classifiedRoles | Where-Object { $_.RiskLevel -eq "High" }).Count -gt 0
        $noSignIn = $false
        if ($hasHighRole) { $risks += T 'risk.privRole' (($classifiedRoles | Where-Object { $_.RiskLevel -eq "High" } | ForEach-Object { $_.RoleName }) -join ", ") }
        if ($_.AccountEnabled -eq "false") { $risks += T 'risk.accountDisabledRoles' }
        if ($hasHighRole -and -not $lastSignIn) { $risks += T 'risk.privNoSignInRecord'; $noSignIn = $true }
        elseif ($daysSinceSignIn -and $daysSinceSignIn -ge 60) { $risks += T 'risk.privNoSignInDays' $daysSinceSignIn; $noSignIn = $true }

        $riskLevel = if ($hasHighRole -or $_.AccountEnabled -eq "false" -or $noSignIn) { "High" } elseif ($risks.Count -gt 0) { "Medium" } else { "Healthy" }

        [PSCustomObject]@{
            DisplayName       = $_.DisplayName
            AppId             = $_.RowKey
            ObjectId          = $_.RowKey
            UserPrincipalName = $_.UserPrincipalName
            AccountEnabled    = ($_.AccountEnabled -eq "true")
            JobTitle          = $_.JobTitle
            Department        = $_.Department
            DirectoryRoles    = $classifiedRoles
            RoleCount         = [int]($_.RoleCount)
            CreatedOn         = $_.CreatedOn
            MarkedForDeletion = if ($tag -and $tag.MarkedForDeletion -eq "true") { $true } else { $false }
            MarkedBy          = if ($tag) { $tag.MarkedBy } else { $null }
            MarkedOn          = if ($tag) { $tag.MarkedOn } else { $null }
            ProposedName      = if ($tag) { $tag.ProposedName } else { $null }
            RenameRequestedBy = if ($tag) { $tag.RenameRequestedBy } else { $null }
            RenameRequestedOn = if ($tag) { $tag.RenameRequestedOn } else { $null }
            NotifyOnExpiry    = if ($tag -and $tag.NotifyOnExpiry -eq "true") { $true } else { $false }
            RiskLevel         = $riskLevel
            RiskReasons       = $risks
            IdentityType      = "privilegeduser"
            Owners            = @()
            Credentials       = @()
            ApiPermissions    = @()
            PendingOwnerChanges = @()
            LastSignInDate    = $lastSignIn
            DaysSinceSignIn   = $daysSinceSignIn
            Advisories        = @()
            ContextPurpose     = if ($tag) { $tag.ContextPurpose } else { $null }
            ContextSystem      = if ($tag) { $tag.ContextSystem } else { $null }
            ContextEnvironment = if ($tag) { $tag.ContextEnvironment } else { $null }
            ContextCriticality = if ($tag) { $tag.ContextCriticality } else { $null }
            ContextUpdatedBy   = if ($tag) { $tag.ContextUpdatedBy } else { $null }
            ContextUpdatedOn   = if ($tag) { $tag.ContextUpdatedOn } else { $null }
        }
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK; Body = $(if (@($result).Count -gt 0) { @($result) | ConvertTo-Json -Depth 10 -AsArray } else { '[]' })
        Headers = @{ "Content-Type" = "application/json" }
    })
    return
}

# ── APP REGISTRATIONS / ENTERPRISE APPS / MANAGED IDENTITIES ──
$ownerReqEntities = Get-AllTableEntities -TableName "AppOwnerRequests"
$reqLookup = @{}
foreach ($r in $ownerReqEntities) {
    if ($r.Status -eq "pending") {
        if (-not $reqLookup.ContainsKey($r.PartitionKey)) { $reqLookup[$r.PartitionKey] = @() }
        $reqLookup[$r.PartitionKey] += [PSCustomObject]@{
            RequestId   = $r.RowKey; Action = $r.Action; TargetUpn = $r.TargetUpn
            TargetName  = $r.TargetName; RequestedBy = $r.RequestedBy; RequestedOn = $r.RequestedOn
        }
    }
}

$result = $cacheEntities | ForEach-Object {
    if ($_.ShapedJson) {
        $o = $_.ShapedJson | ConvertFrom-Json
        $pend = if ($reqLookup.ContainsKey($_.RowKey)) { ,@($reqLookup[$_.RowKey]) } else { ,@() }
        return (Set-Governance -o $o -tag $tagLookup[$_.RowKey] -pendingReqs $pend)
    }
    $owners = if ($_.OwnersJson -and $_.OwnersJson -ne '[]') { try { ,@($_.OwnersJson | ConvertFrom-Json) } catch { ,@() } } else { ,@() }
    $creds  = if ($_.CredsJson  -and $_.CredsJson  -ne '[]') { try { ,@($_.CredsJson  | ConvertFrom-Json) } catch { ,@() } } else { ,@() }
    $roles  = if ($_.RolesJson  -and $_.RolesJson  -ne '[]') { try { ,@($_.RolesJson  | ConvertFrom-Json) } catch { ,@() } } else { ,@() }
    $perms  = if ($_.PermsJson  -and $_.PermsJson  -ne '[]') { try { ,@($_.PermsJson  | ConvertFrom-Json) } catch { ,@() } } else { ,@() }

    $credentials = $creds | ForEach-Object {
        $exp = if ($_.EndDateTime) { try { [datetime]$_.EndDateTime } catch { $null } } else { $null }
        $dl  = if ($exp) { [math]::Floor(($exp - $now).TotalDays) } else { $null }
        $st  = if ($null -eq $dl) { "Unknown" } elseif ($dl -lt 0) { "Expired" } elseif ($dl -le 30) { "Expiring" } else { "Valid" }
        [PSCustomObject]@{ Type = $_.Type; DisplayName = $_.DisplayName; EndDateTime = $_.EndDateTime; DaysLeft = $dl; Status = $st }
    }

    # RiskLevel is precomputed during sync; the fallback branches classify only for cache
    # rows written before precompute, so the page stays correct until the next sync runs.
    $classifiedRoles = $roles | ForEach-Object {
        $lvl = if ($_.PSObject.Properties['RiskLevel'] -and $_.RiskLevel) { $_.RiskLevel } elseif ($highRiskRoles -contains $_.RoleName) { "High" } else { "Medium" }
        [PSCustomObject]@{ RoleName = $_.RoleName; RiskLevel = $lvl }
    }

    $classifiedPerms = $perms | ForEach-Object {
        if ($_.PSObject.Properties['RiskLevel'] -and $_.RiskLevel) {
            [PSCustomObject]@{ Resource = $_.Resource; Permission = $_.Permission; RiskLevel = $_.RiskLevel }
        } else {
            $perm = $_.Permission; $level = "Low"
            foreach ($hp in $highRiskPerms) { if ($perm -match [regex]::Escape($hp)) { $level = "High"; break } }
            if ($level -ne "High") { foreach ($mp in $medRiskPerms) { if ($perm -match [regex]::Escape($mp)) { $level = "Medium"; break } } }
            [PSCustomObject]@{ Resource = $_.Resource; Permission = $perm; RiskLevel = $level }
        }
    }

    $tag         = $tagLookup[$_.RowKey]
    $pendingReqs = if ($reqLookup.ContainsKey($_.RowKey)) { ,@($reqLookup[$_.RowKey]) } else { ,@() }

    $risks       = @()
    # Only enabled owners count as cover — see Get-StaticRisk in SyncIdentityCache-Timer.
    # (Advisories are precomputed during sync only; legacy rows without ShapedJson get none.)
    $liveOwners  = @($owners | Where-Object { $_.Enabled -ne $false })
    $deadOwners  = @($owners | Where-Object { $_.Enabled -eq $false })
    $ownerCount  = $liveOwners.Count
    $hasOwner    = $ownerCount -gt 0
    $hasExpired  = ($credentials | Where-Object { $_.Status -eq "Expired" }).Count -gt 0
    $hasExpiring = ($credentials | Where-Object { $_.Status -eq "Expiring" }).Count -gt 0
    $hasHighRole = ($classifiedRoles | Where-Object { $_.RiskLevel -eq "High" }).Count -gt 0
    $hasHighPerm = ($classifiedPerms | Where-Object { $_.RiskLevel -eq "High" }).Count -gt 0

    $lastSignIn      = if ($_.LastSignInDate -and $_.LastSignInDate -ne "") { $_.LastSignInDate } else { $null }
    $rawDays         = if ($null -ne $_.DaysSinceSignIn) { [int]$_.DaysSinceSignIn } else { $null }
    $daysSinceSignIn = if ($rawDays -and $rawDays -ge 0) { $rawDays } else { $null }
    $staleThreshold  = if ($type -eq "managedidentity") { 90 } else { 180 }

    $orphanedByLeavers = (@($owners).Count -gt 0 -and $ownerCount -eq 0)
    if (-not $hasOwner -and $type -eq "appregistration") {
        $risks += if ($orphanedByLeavers) { T 'risk.noActiveOwner' } else { T 'risk.noOwner' }
    }
    if ($ownerCount -gt 0 -and $deadOwners.Count -gt 0 -and $_.IsFirstParty -ne "true") {
        $risks += T 'risk.ownerDisabled' (($deadOwners | ForEach-Object { $_.DisplayName }) -join ", ")
    }
    if (@($credentials).Count -gt 0 -and $ownerCount -lt 2 -and $type -ne "managedidentity" -and $_.IsFirstParty -ne "true") { $risks += T 'risk.minTwoOwners' $ownerCount }
    if ($hasExpired)  { $risks += T 'risk.expiredCred' }
    if ($hasExpiring) { $risks += T 'risk.expiringCred' }
    if ($hasHighRole) { $risks += T 'risk.privRole' (($classifiedRoles | Where-Object { $_.RiskLevel -eq "High" } | ForEach-Object { $_.RoleName }) -join ", ") }
    if ($hasHighPerm) { $risks += T 'risk.highPerm' }
    if ($type -ne "appregistration" -and $daysSinceSignIn -and $daysSinceSignIn -ge $staleThreshold) { $risks += T 'risk.noSignIn' $daysSinceSignIn }
    $ssoNoCa = $false
    if ($type -eq "enterpriseapp" -and $_.IsFirstParty -ne "true") {
        $caStatusCheck = if ($_.CAStatus) { $_.CAStatus } else { "Unknown" }
        $ssoCheck      = if ($_.SSOMode)  { $_.SSOMode  } else { "None" }
        if ($caStatusCheck -eq "None") {
            if ($ssoCheck -ne "None") { $risks += T 'risk.ssoNoCa'; $ssoNoCa = $true }
            else { $risks += T 'risk.noCa' }
        }
    }

    $highNoOwner = (-not $hasOwner -and $type -eq "appregistration")
    $riskLevel = if ($highNoOwner -or $hasExpired -or $hasHighRole -or $ssoNoCa) { "High" } elseif ($risks.Count -gt 0) { "Medium" } else { "Healthy" }

    $obj = [PSCustomObject]@{
        DisplayName       = $_.DisplayName; AppId = $_.RowKey; ObjectId = $_.ObjectId; CreatedOn = $_.CreatedOn
        Credentials       = $credentials; Owners = $owners; DirectoryRoles = $classifiedRoles; ApiPermissions = $classifiedPerms
        MarkedForDeletion = if ($tag -and $tag.MarkedForDeletion -eq "true") { $true } else { $false }
        MarkedBy          = if ($tag) { $tag.MarkedBy } else { $null }
        MarkedOn          = if ($tag) { $tag.MarkedOn } else { $null }
        ProposedName      = if ($tag) { $tag.ProposedName } else { $null }
        RenameRequestedBy = if ($tag) { $tag.RenameRequestedBy } else { $null }
        RenameRequestedOn = if ($tag) { $tag.RenameRequestedOn } else { $null }
        NotifyOnExpiry   = if ($tag -and $tag.NotifyOnExpiry -eq "true") { $true } else { $false }
        PendingOwnerChanges = $pendingReqs; RiskLevel = $riskLevel; RiskReasons = $risks; IdentityType = $type
        LastSignInDate    = $lastSignIn; DaysSinceSignIn = $daysSinceSignIn
        Advisories        = @(); HasFederation = ($_.HasFederation -eq "true"); FederatedCredentials = @()
        ContextPurpose     = if ($tag) { $tag.ContextPurpose } else { $null }
        ContextSystem      = if ($tag) { $tag.ContextSystem } else { $null }
        ContextEnvironment = if ($tag) { $tag.ContextEnvironment } else { $null }
        ContextCriticality = if ($tag) { $tag.ContextCriticality } else { $null }
        ContextUpdatedBy   = if ($tag) { $tag.ContextUpdatedBy } else { $null }
        ContextUpdatedOn   = if ($tag) { $tag.ContextUpdatedOn } else { $null }
    }

    if ($type -eq "appregistration") {
        $obj | Add-Member -NotePropertyName "HasLinkedSP" -NotePropertyValue ($_.HasLinkedSP -eq "true")
    }
    if ($type -eq "enterpriseapp") {
        $obj | Add-Member -NotePropertyName "AccountEnabled"    -NotePropertyValue ($_.AccountEnabled -eq "true")
        $obj | Add-Member -NotePropertyName "IsFirstParty"      -NotePropertyValue ($_.IsFirstParty -eq "true")
        $obj | Add-Member -NotePropertyName "HasLinkedAppReg"   -NotePropertyValue ($_.HasLinkedAppReg -eq "true")
        $ssoVal = if ($_.SSOMode) { $_.SSOMode } else { "None" }
        $obj | Add-Member -NotePropertyName "SSOMode"           -NotePropertyValue $ssoVal
        $caPolicies  = if ($_.CAPoliciesJson -and $_.CAPoliciesJson -ne '[]') { try { ,@($_.CAPoliciesJson | ConvertFrom-Json) } catch { ,@() } } else { ,@() }
        $caStatusVal = if ($_.CAStatus) { $_.CAStatus } else { "Unknown" }
        $obj | Add-Member -NotePropertyName "CAPolicies"        -NotePropertyValue $caPolicies
        $obj | Add-Member -NotePropertyName "CAStatus"          -NotePropertyValue $caStatusVal
    }
    if ($type -eq "managedidentity") {
        $obj | Add-Member -NotePropertyName "AccountEnabled"      -NotePropertyValue ($_.AccountEnabled -eq "true")
        $obj | Add-Member -NotePropertyName "AzureResourceId"     -NotePropertyValue $_.AzureResourceId
        $obj | Add-Member -NotePropertyName "ManagedIdentityType" -NotePropertyValue $_.ManagedIdentityType
    }
    $obj
}

# Members only see app registrations / enterprise apps they own (case-insensitive UPN match).
if ($caller.IsMember) {
    $u = $caller.Upn
    $result = @($result | Where-Object {
        @($_.Owners | Where-Object { $_.UserPrincipalName -and $_.UserPrincipalName.ToLower() -eq $u }).Count -gt 0
    })
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK; Body = $(if (@($result).Count -gt 0) { @($result) | ConvertTo-Json -Depth 10 -AsArray } else { '[]' })
    Headers = @{ "Content-Type" = "application/json" }
})