param($Timer)

Write-Host "=== Identity Cache sync started ==="

$graphToken = (Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://graph.microsoft.com&api-version=2019-08-01" -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token
$storageToken = (Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://storage.azure.com/&api-version=2019-08-01" -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token

$gH = @{ Authorization = "Bearer $graphToken" }
$tableBaseUri = $env:AzureWebJobsStorage__tableServiceUri
if (-not $tableBaseUri.EndsWith("/")) { $tableBaseUri += "/" }

$now   = (Get-Date).ToString("o")
$nowDt = Get-Date

# ══════════════════════════════════════
# HELPERS
# ══════════════════════════════════════
function Get-StorageHeaders {
    return @{
        Authorization  = "Bearer $storageToken"
        Accept         = "application/json;odata=nometadata"
        "x-ms-version" = "2020-12-06"
        "x-ms-date"    = (Get-Date).ToUniversalTime().ToString("R")
    }
}

# Batch upsert — PUT (InsertOrReplace). Safe to use now that IdentityCache is
# a pure Graph cache: GovernanceState owns all portal-written fields separately.
function Invoke-BatchUpsert {
    param([string]$TableName, [array]$Entities)
    $tableUri = "$tableBaseUri$TableName"
    $batchSize = 100; $success = 0; $fail = 0
    for ($i = 0; $i -lt $Entities.Count; $i += $batchSize) {
        $batch  = $Entities[$i..([Math]::Min($i + $batchSize - 1, $Entities.Count - 1))]
        $batchId = [Guid]::NewGuid().ToString(); $csId = [Guid]::NewGuid().ToString()
        $parts  = @("--batch_$batchId", "Content-Type: multipart/mixed; boundary=changeset_$csId", "")
        foreach ($e in $batch) {
            $json = $e | ConvertTo-Json -Depth 5
            $eUri = "$tableUri(PartitionKey='$($e.PartitionKey)',RowKey='$($e.RowKey)')"
            $parts += "--changeset_$csId", "Content-Type: application/http", "Content-Transfer-Encoding: binary", ""
            $parts += "PUT $eUri HTTP/1.1", "Content-Type: application/json", "Accept: application/json;odata=nometadata", "Prefer: return-no-content", "", $json
        }
        $parts += "--changeset_$csId--", "--batch_$batchId--"
        try {
            Invoke-RestMethod -Method POST -Uri "$tableBaseUri`$batch" -Headers @{
                Authorization  = "Bearer $storageToken"
                "Content-Type" = "multipart/mixed; boundary=batch_$batchId"
                Accept         = "application/json;odata=nometadata"
                "x-ms-version" = "2020-12-06"
                "x-ms-date"    = (Get-Date).ToUniversalTime().ToString("R")
            } -Body ($parts -join "`r`n") | Out-Null
            $success += $batch.Count
        } catch { $fail += $batch.Count; Write-Warning "Batch failed: $($_.Exception.Message)" }
    }
    Write-Host "$TableName upsert: $success ok, $fail failed"
}

# Delete all rows in a partition — used to clear stale entities before reinserting.
# Reads only RowKey (cheap), then deletes individually.
function Clear-Partition {
    param([string]$Partition)
    $tableUri    = "${tableBaseUri}IdentityCache"
    $filterValue = [System.Uri]::EscapeDataString("PartitionKey eq '$Partition'")
    $uri         = "$tableUri()?" + '$filter=' + "$filterValue&`$select=RowKey&`$top=1000"
    $rowKeys     = @()

    do {
        $h      = Get-StorageHeaders
        $resp   = Invoke-WebRequest -Method GET -Uri $uri -Headers $h -UseBasicParsing
        $parsed = $resp.Content | ConvertFrom-Json
        $rowKeys += $parsed.value | ForEach-Object { $_.RowKey }
        $np = $resp.Headers["x-ms-continuation-NextPartitionKey"]; if ($np -is [array]) { $np = $np[0] }
        $nr = $resp.Headers["x-ms-continuation-NextRowKey"];       if ($nr -is [array]) { $nr = $nr[0] }
        if (-not [string]::IsNullOrWhiteSpace($np)) {
            $uri = "$tableUri()?" + '$filter=' + "$filterValue&`$select=RowKey&`$top=1000&NextPartitionKey=$np"
            if (-not [string]::IsNullOrWhiteSpace($nr)) { $uri += "&NextRowKey=$nr" }
        } else { $uri = $null }
    } while ($uri)

    if ($rowKeys.Count -eq 0) {
        Write-Host "Partition '$Partition' is already empty"
        return
    }

    Write-Host "Batch-deleting $($rowKeys.Count) rows from partition '$Partition'"
    $batchSize = 100; $success = 0; $fail = 0

    for ($i = 0; $i -lt $rowKeys.Count; $i += $batchSize) {
        $batch   = $rowKeys[$i..([Math]::Min($i + $batchSize - 1, $rowKeys.Count - 1))]
        $batchId = [Guid]::NewGuid().ToString()
        $csId    = [Guid]::NewGuid().ToString()
        $parts   = @("--batch_$batchId", "Content-Type: multipart/mixed; boundary=changeset_$csId", "")

        foreach ($rowKey in $batch) {
            $eUri = "$tableUri(PartitionKey='$Partition',RowKey='$rowKey')"
            $parts += "--changeset_$csId", "Content-Type: application/http", "Content-Transfer-Encoding: binary", ""
            $parts += "DELETE $eUri HTTP/1.1", "Accept: application/json;odata=nometadata", "If-Match: *", ""
        }
        $parts += "--changeset_$csId--", "--batch_$batchId--"

        try {
            Invoke-RestMethod -Method POST -Uri "$tableBaseUri`$batch" -Headers @{
                Authorization  = "Bearer $storageToken"
                "Content-Type" = "multipart/mixed; boundary=batch_$batchId"
                Accept         = "application/json;odata=nometadata"
                "x-ms-version" = "2020-12-06"
                "x-ms-date"    = (Get-Date).ToUniversalTime().ToString("R")
            } -Body ($parts -join "`r`n") | Out-Null
            $success += $batch.Count
        } catch {
            $fail += $batch.Count
            Write-Warning "Delete batch failed for partition '$Partition' at offset $i`: $($_.Exception.Message)"
        }
    }
    Write-Host "Partition '$Partition' cleared: $success deleted, $fail failed"
}

function Get-CredJson { param($pw, $key)
    $all = @()
    # KeyId is carried through so downstream consumers (e.g. expiry notifications) can
    # dedup per individual credential — a rotated secret gets a new keyId and is treated
    # as a distinct credential rather than being suppressed by a stale notification record.
    $pw  | ForEach-Object { $all += @{ KeyId = $_.keyId; DisplayName = $_.displayName; EndDateTime = $_.endDateTime; Type = "Secret" } }
    $key | ForEach-Object { $all += @{ KeyId = $_.keyId; DisplayName = $_.displayName; EndDateTime = $_.endDateTime; Type = "Certificate" } }
    if ($all.Count -gt 0) { $all | ConvertTo-Json -Compress } else { "[]" }
}

# ── Risk classification, precomputed here so GetIdentities doesn't re-run it per request ──
$highRiskRoles = @("Global Administrator", "Privileged Role Administrator", "Exchange Administrator", "SharePoint Administrator", "Application Administrator", "Cloud Application Administrator", "Privileged Authentication Administrator", "Authentication Administrator", "Security Administrator", "User Administrator", "Intune Administrator", "Compliance Administrator")
$highRiskPerms = @("ReadWrite.All", "FullControl.All", "Mail.ReadWrite", "Mail.Send", "Files.ReadWrite.All", "Sites.FullControl.All", "Directory.ReadWrite.All", "RoleManagement.ReadWrite.Directory", "AppRoleAssignment.ReadWrite.All", "Application.ReadWrite.All", "User.ReadWrite.All", "Group.ReadWrite.All")
$medRiskPerms  = @("Read.All", "User.Read.All", "Mail.Read", "Files.Read.All", "Sites.Read.All", "Directory.Read.All", "AuditLog.Read.All", "Group.Read.All")

# Emit roles as [{RoleName, RiskLevel}] objects so both the cache column and the
# precomputed ShapedJson can use them verbatim (read path does no reclassification).
function Get-ClassifiedRoles { param($roles)
    if (-not $roles -or $roles.Count -eq 0) { return @() }
    @($roles | ForEach-Object { [PSCustomObject]@{ RoleName = $_.RoleName; RiskLevel = if ($highRiskRoles -contains $_.RoleName) { "High" } else { "Medium" } } })
}
function Get-ClassifiedRolesJson { param($roles)
    $c = Get-ClassifiedRoles $roles
    if ($c.Count -eq 0) { return "[]" }
    return (,$c | ConvertTo-Json -Compress)
}

# Emit perms as [{Resource, Permission, RiskLevel}] — the regex matching (the expensive
# part of the old read path) now runs once per sync instead of on every API call.
function Get-ClassifiedPerms { param($perms)
    if (-not $perms -or $perms.Count -eq 0) { return @() }
    @($perms | ForEach-Object {
        $perm = $_.Permission; $level = "Low"
        foreach ($hp in $highRiskPerms) { if ($perm -match [regex]::Escape($hp)) { $level = "High"; break } }
        if ($level -ne "High") { foreach ($mp in $medRiskPerms) { if ($perm -match [regex]::Escape($mp)) { $level = "Medium"; break } } }
        [PSCustomObject]@{ Resource = $_.Resource; Permission = $perm; RiskLevel = $level }
    })
}
function Get-ClassifiedPermsJson { param($perms)
    $c = Get-ClassifiedPerms $perms
    if ($c.Count -eq 0) { return "[]" }
    return (,$c | ConvertTo-Json -Compress)
}

# ── ShapedJson precompute ────────────────────────────────────────────────────
# Builds the fully-shaped per-identity object the portal consumes, MINUS the live
# governance overlay (deletion tags, rename requests, notify opt-in, pending owner
# changes, which the read path applies fresh from GovernanceState/AppOwnerRequests).
# Credential status and the full risk verdict are computed here so GetIdentities does no per-row
# JSON parsing, classification, or object construction — only a single deserialize +
# governance overlay. Governance placeholders are included so the object shape is
# identical to the final response and the read path only overwrites values.

# Build shaped credentials [{Type,DisplayName,EndDateTime,DaysLeft,Status,LifetimeDays}] from raw Graph creds.
# LifetimeDays (start→end) is what the secret-lifetime standard is judged against; it is
# fixed at issue time, unlike DaysLeft which counts down.
function Build-ShapedCreds { param($pw, $key)
    $raw = @()
    $pw  | ForEach-Object { $raw += [PSCustomObject]@{ Type = "Secret";      DisplayName = $_.displayName; EndDateTime = $_.endDateTime; StartDateTime = $_.startDateTime } }
    $key | ForEach-Object { $raw += [PSCustomObject]@{ Type = "Certificate"; DisplayName = $_.displayName; EndDateTime = $_.endDateTime; StartDateTime = $_.startDateTime } }
    @($raw | ForEach-Object {
        $exp = if ($_.EndDateTime) { try { [datetime]$_.EndDateTime } catch { $null } } else { $null }
        $srt = if ($_.StartDateTime) { try { [datetime]$_.StartDateTime } catch { $null } } else { $null }
        $dl  = if ($exp) { [math]::Floor(($exp - $nowDt).TotalDays) } else { $null }
        $lt  = if ($exp -and $srt) { [math]::Floor(($exp - $srt).TotalDays) } else { $null }
        $st  = if ($null -eq $dl) { "Unknown" } elseif ($dl -lt 0) { "Expired" } elseif ($dl -le 30) { "Expiring" } else { "Valid" }
        [PSCustomObject]@{ Type = $_.Type; DisplayName = $_.DisplayName; EndDateTime = $_.EndDateTime; DaysLeft = $dl; Status = $st; LifetimeDays = $lt }
    })
}

# Risk reasons + level. Fully determined here — the read path only overlays governance
# state (deletion tags, rename requests, notify opt-in) and does no risk scoring.
function Get-StaticRisk {
    param($Type, $Owners, $Creds, $Roles, $Perms, $DaysSinceSignIn, [string]$IsFirstParty, [string]$CAStatus, [string]$SSOMode)
    $reasons = @()
    $allOwners     = @($Owners)
    # Only an enabled owner can actually act on this app, so every ownership rule counts
    # enabled accounts — a departed owner is not cover.
    $liveOwners    = @($allOwners | Where-Object { $_.Enabled -ne $false })
    $deadOwners    = @($allOwners | Where-Object { $_.Enabled -eq $false })
    $OwnerCount    = $liveOwners.Count
    $HasOwner      = $OwnerCount -gt 0
    $hasExpired  = ($Creds  | Where-Object { $_.Status   -eq "Expired" }).Count  -gt 0
    $hasExpiring = ($Creds  | Where-Object { $_.Status   -eq "Expiring" }).Count -gt 0
    $highRoles   = @($Roles | Where-Object { $_.RiskLevel -eq "High" } | ForEach-Object { $_.RoleName })
    $hasHighPerm = ($Perms  | Where-Object { $_.RiskLevel -eq "High" }).Count   -gt 0
    $stale       = if ($Type -eq "managedidentity") { 90 } else { 180 }

    # Unowned app registration → High (your org authored it, it must have an owner).
    # Unowned non-first-party enterprise app → flagged, but Medium: it's a common state
    # (especially third-party) and shouldn't flood the High bucket. First-party Microsoft
    # apps are never expected to have a tenant owner, so they're not flagged at all.
    # "Orphaned" covers both never-owned and owned-only-by-leavers: the effect is identical,
    # nobody is receiving this app's mail. Called out separately so the fix is obvious.
    $orphanedByLeavers = ($allOwners.Count -gt 0 -and $OwnerCount -eq 0)
    if (-not $HasOwner -and $Type -eq "appregistration") {
        $reasons += if ($orphanedByLeavers) { T 'risk.noActiveOwner' } else { T 'risk.noOwner' }
    }
    $entNoOwner = (-not $HasOwner -and $Type -eq "enterpriseapp" -and $IsFirstParty -ne "true")
    if ($entNoOwner) {
        $reasons += if ($orphanedByLeavers) { T 'risk.noActiveOwner' } else { T 'risk.noOwnerAssigned' }
    }
    if ($OwnerCount -gt 0 -and $deadOwners.Count -gt 0 -and $IsFirstParty -ne "true") {
        $reasons += T 'risk.ownerDisabled' (($deadOwners | ForEach-Object { $_.DisplayName }) -join ", ")
    }
    # A credential is a shared secret with a renewal duty — one owner is a single point of
    # failure (they leave, it expires, nobody notices). Flagged, but never on its own a High.
    # Microsoft first-party SPs are skipped for the same reason they're skipped above: a
    # tenant is not expected to own them.
    if (@($Creds).Count -gt 0 -and $OwnerCount -lt 2 -and $Type -ne "managedidentity" -and $IsFirstParty -ne "true") {
        $reasons += T 'risk.minTwoOwners' $OwnerCount
    }
    if ($hasExpired)  { $reasons += T 'risk.expiredCred' }
    if ($hasExpiring) { $reasons += T 'risk.expiringCred' }
    if ($highRoles.Count -gt 0) { $reasons += T 'risk.privRole' ($highRoles -join ", ") }
    if ($hasHighPerm) { $reasons += T 'risk.highPerm' }
    if ($Type -ne "appregistration" -and $DaysSinceSignIn -and $DaysSinceSignIn -ge $stale) { $reasons += T 'risk.noSignIn' $DaysSinceSignIn }
    $ssoNoCa = $false
    if ($Type -eq "enterpriseapp" -and $IsFirstParty -ne "true" -and $CAStatus -eq "None") {
        if ($SSOMode -and $SSOMode -ne "None") { $reasons += T 'risk.ssoNoCa'; $ssoNoCa = $true }
        else { $reasons += T 'risk.noCa' }
    }

    # High: app-reg without owner, expired cred, privileged role, or SSO app with no CA.
    # Decided on the conditions, not the reason text, which is in the deployment's language.
    $highAppRegNoOwner = (-not $HasOwner -and $Type -eq "appregistration")
    $highOther = $hasExpired -or ($highRoles.Count -gt 0) -or $ssoNoCa
    $level = if ($highAppRegNoOwner -or $highOther) { "High" }
             elseif ($reasons.Count -gt 0) { "Medium" } else { "Healthy" }
    return @{ Reasons = $reasons; Level = $level }
}

# ── Advisories ───────────────────────────────────────────────────────────────
# Improvement hints, deliberately kept OUT of RiskReasons so they never move an identity's
# risk level or the tenant health score. Nothing here is a defect — it's the "how do we
# stop doing this repeatedly" advice, shown where the owner is already looking.
$secretMaxLifetimeDays = if ($env:SECRET_MAX_LIFETIME_DAYS) { [int]$env:SECRET_MAX_LIFETIME_DAYS } else { 365 }

function Get-Advisories {
    param($Type, $Creds, $FederatedCreds)
    $advice  = @()
    $secrets = @($Creds | Where-Object { $_.Type -eq "Secret" })
    $hasFed  = @($FederatedCreds).Count -gt 0

    if ($secrets.Count -gt 0 -and $hasFed) {
        $advice += T 'adv.fedConfigured'
    }
    # Only suggest federation at the moment it is actionable: someone is about to renew.
    # Suggesting it on every secret-bearing app would put a hint on nearly every row.
    elseif ($secrets.Count -gt 0 -and $Type -eq "appregistration" -and @($secrets | Where-Object { $_.Status -eq "Expiring" -or $_.Status -eq "Expired" }).Count -gt 0) {
        $advice += T 'adv.considerFederation'
    }

    $longLived = @($secrets | Where-Object { $_.LifetimeDays -and $_.LifetimeDays -gt $secretMaxLifetimeDays })
    if ($longLived.Count -gt 0) {
        $months = [math]::Round((($longLived | ForEach-Object { $_.LifetimeDays } | Measure-Object -Maximum).Maximum) / 30.4)
        $stdMon = [math]::Round($secretMaxLifetimeDays / 30.4)
        $advice += T 'adv.secretLifetime' $months $stdMon
    }
    return $advice
}

# Assemble the shaped object (governance placeholders included) and return compact JSON.
function Get-ShapedJson { param([hashtable]$Obj)
    return ($Obj | ConvertTo-Json -Compress -Depth 6)
}

# ══════════════════════════════════════
# 1. FETCH SERVICE PRINCIPAL SIGN-IN ACTIVITIES
#    Requires AuditLog.Read.All on the managed identity.
#    Merged here to eliminate the race condition that existed when
#    SyncSignInActivity ran as a separate 30-min timer.
# ══════════════════════════════════════
Write-Host "--- Fetching service principal sign-in activities ---"
$allSignIns = @{}
$uri = "https://graph.microsoft.com/beta/reports/servicePrincipalSignInActivities?`$top=999"
$pageCount = 0

do {
    try {
        $r = Invoke-RestMethod -Method GET -Uri $uri -Headers $gH
        foreach ($entry in $r.value) {
            $lastDate = $null
            if ($entry.lastSignInActivity -and $entry.lastSignInActivity.lastSignInDateTime) {
                $lastDate = $entry.lastSignInActivity.lastSignInDateTime
            }
            if (-not $lastDate) {
                $candidates = @()
                if ($entry.applicationAuthenticationClientSignInActivity  -and $entry.applicationAuthenticationClientSignInActivity.lastSignInDateTime)   { $candidates += $entry.applicationAuthenticationClientSignInActivity.lastSignInDateTime }
                if ($entry.delegatedClientSignInActivity                   -and $entry.delegatedClientSignInActivity.lastSignInDateTime)                   { $candidates += $entry.delegatedClientSignInActivity.lastSignInDateTime }
                if ($entry.applicationAuthenticationResourceSignInActivity -and $entry.applicationAuthenticationResourceSignInActivity.lastSignInDateTime)  { $candidates += $entry.applicationAuthenticationResourceSignInActivity.lastSignInDateTime }
                if ($entry.delegatedResourceSignInActivity                 -and $entry.delegatedResourceSignInActivity.lastSignInDateTime)                 { $candidates += $entry.delegatedResourceSignInActivity.lastSignInDateTime }
                if ($candidates.Count -gt 0) { $lastDate = ($candidates | Sort-Object -Descending | Select-Object -First 1) }
            }
            if ($lastDate) { $allSignIns[$entry.appId] = $lastDate }
        }
        $uri = $r.'@odata.nextLink'
        $pageCount++
    } catch {
        Write-Warning "Sign-in activity fetch failed: $($_.Exception.Message)"
        if ($_.Exception.Message -match "403|Forbidden|Authorization") {
            # Enrichment only — a missing AuditLog.Read.All must NOT abort the whole sync
            # (the identity cache + ShapedJson still need to be rebuilt). Warn, don't error.
            Write-Warning "PERMISSION: Managed identity needs AuditLog.Read.All for servicePrincipalSignInActivities. Sign-in data will be blank until granted; continuing sync."
        }
        $uri = $null
    }
} while ($uri)

Write-Host "Fetched sign-in data for $($allSignIns.Count) service principals across $pageCount pages"

function Get-SignInFields { param([string]$AppId)
    $lastDate = $allSignIns[$AppId]
    if ($lastDate) {
        $days = $null
        try { $days = [math]::Floor(($nowDt - [datetime]$lastDate).TotalDays) } catch {}
        return @{ LastSignInDate = $lastDate; DaysSinceSignIn = if ($null -ne $days) { $days } else { -1 }; SignInSynced = $now }
    }
    return @{ LastSignInDate = ""; DaysSinceSignIn = -1; SignInSynced = $now }
}

# ══════════════════════════════════════
# 2. FETCH ALL SERVICE PRINCIPALS
# ══════════════════════════════════════
Write-Host "--- Fetching all service principals ---"
$allServicePrincipals = @()
$uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$select=id,displayName,appId,servicePrincipalType,appOwnerOrganizationId,accountEnabled,createdDateTime,passwordCredentials,keyCredentials,alternativeNames,appRoles,preferredSingleSignOnMode&`$top=999"
do {
    $r = Invoke-RestMethod -Method GET -Uri $uri -Headers $gH
    $allServicePrincipals += $r.value
    $uri = $r.'@odata.nextLink'
} while ($uri)
Write-Host "Fetched $($allServicePrincipals.Count) total service principals"

$spByAppId = @{}; $spById = @{}
foreach ($sp in $allServicePrincipals) { $spByAppId[$sp.appId] = $sp; $spById[$sp.id] = $sp }

# ══════════════════════════════════════
# 3. FETCH DIRECTORY ROLE ASSIGNMENTS
# ══════════════════════════════════════
Write-Host "--- Fetching directory role assignments ---"
$allRoleAssignments = @()
$uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$expand=roleDefinition&`$top=999"
do {
    $r = Invoke-RestMethod -Method GET -Uri $uri -Headers $gH
    $allRoleAssignments += $r.value
    $uri = $r.'@odata.nextLink'
} while ($uri)
Write-Host "Fetched $($allRoleAssignments.Count) role assignments"

$rolesBySp = @{}
foreach ($ra in $allRoleAssignments) {
    if ($spById.ContainsKey($ra.principalId)) {
        if (-not $rolesBySp.ContainsKey($ra.principalId)) { $rolesBySp[$ra.principalId] = @() }
        $roleName = if ($ra.roleDefinition) { $ra.roleDefinition.displayName } else { "Unknown Role" }
        $rolesBySp[$ra.principalId] += @{ RoleName = $roleName; RoleId = $ra.roleDefinitionId }
    }
}
Write-Host "Mapped roles to $($rolesBySp.Count) service principals"

# ══════════════════════════════════════
# 4. FETCH API PERMISSIONS via Graph $batch
# ══════════════════════════════════════
Write-Host "--- Fetching API permissions (bulk) ---"

$appRoleLookup = @{}
foreach ($sp in $allServicePrincipals) {
    if ($sp.appRoles) {
        foreach ($role in $sp.appRoles) { $appRoleLookup["$($sp.id)|$($role.id)"] = $role.value }
    }
}

$resourceSpNames = @{}
foreach ($sp in $allServicePrincipals) { $resourceSpNames[$sp.id] = $sp.displayName }

$permsBySp = @{}
$relevantSPs = @($allServicePrincipals | Where-Object {
    ($_.servicePrincipalType -eq "Application" -or $_.servicePrincipalType -eq "ManagedIdentity") -and
    $_.appOwnerOrganizationId -ne "f8cdef31-a31e-4b4a-93e4-5f571e91255a"
})
Write-Host "Querying permissions for $($relevantSPs.Count) non-Microsoft SPs..."

for ($i = 0; $i -lt $relevantSPs.Count; $i += 20) {
    $batch = $relevantSPs[$i..([Math]::Min($i + 19, $relevantSPs.Count - 1))]
    $batchRequests = @(); $idx = 0
    foreach ($sp in $batch) {
        $batchRequests += @{ id = "$idx"; method = "GET"; url = "/servicePrincipals/$($sp.id)/appRoleAssignments" }
        $idx++
    }
    try {
        $batchResponse = Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/`$batch" -Headers @{
            Authorization = "Bearer $graphToken"; "Content-Type" = "application/json"
        } -Body (@{ requests = $batchRequests } | ConvertTo-Json -Depth 5)

        foreach ($resp in $batchResponse.responses) {
            $sp = $batch[[int]$resp.id]
            if ($resp.status -eq 200 -and $resp.body.value) {
                $perms = @()
                foreach ($p in $resp.body.value) {
                    $rn = $resourceSpNames[$p.resourceId]; if (-not $rn) { $rn = $p.resourceDisplayName }
                    $pn = $appRoleLookup["$($p.resourceId)|$($p.appRoleId)"]; if (-not $pn) { $pn = $p.appRoleId }
                    $perms += @{ Resource = $rn; Permission = $pn }
                }
                if ($perms.Count -gt 0) { $permsBySp[$sp.id] = $perms }
            }
        }
    } catch { Write-Warning "Batch at offset $i failed: $($_.Exception.Message)" }
}
Write-Host "Fetched permissions for $($permsBySp.Count) service principals"

function Get-RP { param([string]$AppId)
    $sp = $spByAppId[$AppId]; $ro = @(); $pe = @()
    if ($sp) { $ro = Get-ClassifiedRoles $rolesBySp[$sp.id]; $pe = Get-ClassifiedPerms $permsBySp[$sp.id] }
    $rj = if ($ro.Count) { (,$ro | ConvertTo-Json -Compress) } else { "[]" }
    $pj = if ($pe.Count) { (,$pe | ConvertTo-Json -Compress) } else { "[]" }
    return @{ RolesJson = $rj; PermsJson = $pj; Roles = $ro; Perms = $pe }
}

# ══════════════════════════════════════
# 4b. FETCH ENTERPRISE APP (SP) OWNERS via Graph $batch
#    Owners live on the service principal independently of any app registration, so we
#    read them directly for every enterprise app (first- and third-party). Managed
#    identities are excluded — they are owned by their Azure resource via RBAC, not by
#    directory owners. Read is permitted by Application.Read.All / Directory.Read.All.
# ══════════════════════════════════════
Write-Host "--- Fetching enterprise app owners (bulk) ---"
$ownersBySpId = @{}
$ownerSPs = @($allServicePrincipals | Where-Object { $_.servicePrincipalType -eq "Application" })
Write-Host "Querying owners for $($ownerSPs.Count) enterprise apps..."

for ($i = 0; $i -lt $ownerSPs.Count; $i += 20) {
    $batch = $ownerSPs[$i..([Math]::Min($i + 19, $ownerSPs.Count - 1))]
    $batchRequests = @(); $idx = 0
    foreach ($sp in $batch) {
        # accountEnabled comes along so a departed owner (disabled account) can be detected —
        # a sole disabled owner means nobody is actually receiving this app's expiry mail.
        $batchRequests += @{ id = "$idx"; method = "GET"; url = "/servicePrincipals/$($sp.id)/owners?`$select=id,displayName,userPrincipalName,accountEnabled" }
        $idx++
    }
    try {
        $batchResponse = Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/`$batch" -Headers @{
            Authorization = "Bearer $graphToken"; "Content-Type" = "application/json"
        } -Body (@{ requests = $batchRequests } | ConvertTo-Json -Depth 5)

        foreach ($resp in $batchResponse.responses) {
            $sp = $batch[[int]$resp.id]
            if ($resp.status -eq 200 -and $resp.body.value) {
                $owners = @()
                # Groups and other non-user owners carry no accountEnabled — absent is treated
                # as enabled so they never raise a false "departed owner" flag.
                foreach ($o in $resp.body.value) { $owners += @{ DisplayName = $o.displayName; UserPrincipalName = $o.userPrincipalName; Enabled = ($o.accountEnabled -ne $false) } }
                if ($owners.Count -gt 0) { $ownersBySpId[$sp.id] = $owners }
            }
        }
    } catch { Write-Warning "Owner batch at offset $i failed: $($_.Exception.Message)" }
}
Write-Host "Fetched owners for $($ownersBySpId.Count) enterprise apps"

# ══════════════════════════════════════
# 5. FETCH CONDITIONAL ACCESS POLICIES
#    Requires Policy.Read.All on the managed identity.
# ══════════════════════════════════════
Write-Host "--- Fetching Conditional Access policies ---"
$caPolicies = @()
$uri = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?`$select=id,displayName,state,conditions"
do {
    try {
        $r = Invoke-RestMethod -Method GET -Uri $uri -Headers $gH
        $caPolicies += $r.value
        $uri = $r.'@odata.nextLink'
    } catch {
        Write-Warning "CA policy fetch failed: $($_.Exception.Message)"
        if ($_.Exception.Message -match "403|Forbidden") {
            Write-Warning "CA PERMISSION: Managed identity requires Policy.Read.All. Grant app role 246dd0d5-5bd0-4def-940b-0421030a5b68 and re-run."
        }
        $uri = $null
    }
} while ($uri)
Write-Host "Fetched $($caPolicies.Count) CA policies"

$entAppIds = @{}
foreach ($sp in $allServicePrincipals) {
    if ($sp.servicePrincipalType -eq "Application") { $entAppIds[$sp.appId] = $sp.displayName }
}

$caByAppId = @{}
foreach ($policy in $caPolicies) {
    if ($policy.state -ne "enabled") { continue }
    $includes  = @($policy.conditions.applications.includeApplications)
    $excludes  = @($policy.conditions.applications.excludeApplications)
    $coversAll = $includes -contains "All"
    foreach ($appId in $entAppIds.Keys) {
        $excluded = $excludes -contains $appId
        $covered  = ($coversAll -or $includes -contains $appId) -and -not $excluded
        if ($covered) {
            if (-not $caByAppId.ContainsKey($appId)) { $caByAppId[$appId] = @() }
            $caByAppId[$appId] += $policy.displayName
        }
    }
}
Write-Host "CA coverage mapped for $($caByAppId.Count) enterprise apps"

# ══════════════════════════════════════
# 6. SYNC APP REGISTRATIONS
#    Clear partition first — GovernanceState owns all portal fields,
#    so delete-and-reinsert is now safe with no data loss risk.
# ══════════════════════════════════════
Write-Host "--- Syncing App Registrations ---"
$allApps = @()
$uri = "https://graph.microsoft.com/v1.0/applications?`$select=id,displayName,appId,createdDateTime,passwordCredentials,keyCredentials&`$expand=owners(`$select=displayName,userPrincipalName,accountEnabled)"
do { $r = Invoke-RestMethod -Method GET -Uri $uri -Headers $gH; $allApps += $r.value; $uri = $r.'@odata.nextLink' } while ($uri)
Write-Host "Fetched $($allApps.Count) app registrations"

# ── Federated identity credentials (workload identity federation) ──
# Not expandable on /applications, so batch the navigation property. An app that already
# federates has no need of a client secret; surfacing that turns a renewal into a removal.
Write-Host "--- Fetching federated identity credentials (bulk) ---"
$fedByAppObjId = @{}
for ($i = 0; $i -lt $allApps.Count; $i += 20) {
    $batch = $allApps[$i..([Math]::Min($i + 19, $allApps.Count - 1))]
    $batchRequests = @(); $idx = 0
    foreach ($app in $batch) {
        $batchRequests += @{ id = "$idx"; method = "GET"; url = "/applications/$($app.id)/federatedIdentityCredentials" }
        $idx++
    }
    try {
        $batchResponse = Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/`$batch" -Headers @{
            Authorization = "Bearer $graphToken"; "Content-Type" = "application/json"
        } -Body (@{ requests = $batchRequests } | ConvertTo-Json -Depth 5)
        foreach ($resp in $batchResponse.responses) {
            $app = $batch[[int]$resp.id]
            if ($resp.status -eq 200 -and $resp.body.value) {
                $fc = @($resp.body.value | ForEach-Object { [PSCustomObject]@{ Name = $_.name; Issuer = $_.issuer; Subject = $_.subject } })
                if ($fc.Count -gt 0) { $fedByAppObjId[$app.id] = $fc }
            }
        }
    } catch { Write-Warning "Federated credential batch at offset $i failed: $($_.Exception.Message)" }
}
Write-Host "Found federated credentials on $($fedByAppObjId.Count) app registrations"

Clear-Partition -Partition "appregistration"

$appEntities = $allApps | ForEach-Object {
    $owners     = @($_.owners | ForEach-Object { [PSCustomObject]@{ DisplayName = $_.displayName; UserPrincipalName = $_.userPrincipalName; Enabled = ($_.accountEnabled -ne $false) } })
    $ownersJson = if ($owners.Count -gt 0) { (,$owners | ConvertTo-Json -Compress) } else { "[]" }
    $credsJson  = Get-CredJson -pw $_.passwordCredentials -key $_.keyCredentials
    $rp         = Get-RP -AppId $_.appId
    $shapedCr   = Build-ShapedCreds -pw $_.passwordCredentials -key $_.keyCredentials
    $fedCreds   = if ($fedByAppObjId.ContainsKey($_.id)) { @($fedByAppObjId[$_.id]) } else { @() }
    $risk       = Get-StaticRisk -Type "appregistration" -Owners $owners -Creds $shapedCr -Roles $rp.Roles -Perms $rp.Perms
    $advice     = Get-Advisories -Type "appregistration" -Creds $shapedCr -FederatedCreds $fedCreds
    $shaped     = @{
        DisplayName = $_.displayName; AppId = $_.appId; ObjectId = $_.id; CreatedOn = $_.createdDateTime
        Credentials = $shapedCr; Owners = $owners; DirectoryRoles = $rp.Roles; ApiPermissions = $rp.Perms
        MarkedForDeletion = $false; MarkedBy = $null; MarkedOn = $null; ProposedName = $null
        RenameRequestedBy = $null; RenameRequestedOn = $null; NotifyOnExpiry = $false
        ContextPurpose = $null; ContextSystem = $null; ContextEnvironment = $null
        ContextCriticality = $null; ContextUpdatedBy = $null; ContextUpdatedOn = $null
        PendingOwnerChanges = @(); RiskLevel = $risk.Level; RiskReasons = @($risk.Reasons); IdentityType = "appregistration"
        LastSignInDate = $null; DaysSinceSignIn = $null
        HasLinkedSP = $spByAppId.ContainsKey($_.appId)
        Advisories = @($advice); FederatedCredentials = $fedCreds; HasFederation = ($fedCreds.Count -gt 0)
    }
    @{
        PartitionKey   = "appregistration"; RowKey = $_.appId
        DisplayName    = $_.displayName; ObjectId = $_.id
        OwnersJson     = $ownersJson; CredsJson = $credsJson
        RolesJson      = $rp.RolesJson; PermsJson = $rp.PermsJson
        HasCredentials = if ($_.passwordCredentials.Count -gt 0 -or $_.keyCredentials.Count -gt 0) { "true" } else { "false" }
        HasLinkedSP    = if ($spByAppId.ContainsKey($_.appId)) { "true" } else { "false" }
        HasFederation  = if ($fedCreds.Count -gt 0) { "true" } else { "false" }
        CreatedOn      = $_.createdDateTime; LastSynced = $now
        ShapedJson     = Get-ShapedJson $shaped
    }
}
Invoke-BatchUpsert -TableName "IdentityCache" -Entities $appEntities

# ══════════════════════════════════════
# 7. SYNC ENTERPRISE APPS
# ══════════════════════════════════════
Write-Host "--- Syncing Enterprise Apps ---"
$entApps = @($allServicePrincipals | Where-Object { $_.servicePrincipalType -eq "Application" })
Write-Host "Processing $($entApps.Count) enterprise apps"

$appRegAppIds = @{}; foreach ($app in $allApps) { $appRegAppIds[$app.appId] = $true }
# appId → app registration objectId, so a service principal can look up the federation
# state of the app registration behind it (federated credentials live on the app, not the SP).
$appRegObjIdByAppId = @{}; foreach ($app in $allApps) { $appRegObjIdByAppId[$app.appId] = $app.id }

Clear-Partition -Partition "enterpriseapp"

$spEntities = $entApps | ForEach-Object {
    $credsJson       = Get-CredJson -pw $_.passwordCredentials -key $_.keyCredentials
    $shapedCr        = Build-ShapedCreds -pw $_.passwordCredentials -key $_.keyCredentials
    $isFirstParty    = if ($_.appOwnerOrganizationId -eq "f8cdef31-a31e-4b4a-93e4-5f571e91255a") { "true" } else { "false" }
    $hasLinkedAppReg = if ($appRegAppIds.ContainsKey($_.appId)) { "true" } else { "false" }
    # Guard against $null: piping a missing hashtable key to ForEach-Object would run the
    # block once with $_ = $null, producing a phantom {null,null} owner — which is why
    # ownerless apps showed an "Unknown" owner and the owner filter matched everything.
    $ownerList       = $ownersBySpId[$_.id]
    # Enabled must be carried through here — every downstream check reads it as "-ne $false",
    # so dropping it silently marks every departed owner as active and disables leaver
    # detection for enterprise apps without raising an error anywhere.
    $owners          = if ($ownerList) { @($ownerList | ForEach-Object { [PSCustomObject]@{ DisplayName = $_.DisplayName; UserPrincipalName = $_.UserPrincipalName; Enabled = ($_.Enabled -ne $false) } }) } else { @() }
    $ownersJson      = if ($owners.Count -gt 0) { (,$owners | ConvertTo-Json -Compress) } else { "[]" }
    $roleObjs        = Get-ClassifiedRoles $rolesBySp[$_.id]
    $permObjs        = Get-ClassifiedPerms $permsBySp[$_.id]
    $rolesJson       = if ($roleObjs.Count) { (,$roleObjs | ConvertTo-Json -Compress) } else { "[]" }
    $permsJson       = if ($permObjs.Count) { (,$permObjs | ConvertTo-Json -Compress) } else { "[]" }

    $rawSso  = $_.preferredSingleSignOnMode
    $ssoMode = if ($rawSso -and $rawSso -ne "notSupported") {
        switch ($rawSso.ToLower()) {
            "saml"     { "SAML" }
            "oidc"     { "OIDC" }
            "password" { "Password" }
            default    { $rawSso }
        }
    } elseif (-not $rawSso -and $hasLinkedAppReg -eq "true") { "OIDC (inferred)" }
    else { "None" }

    $caPolicyNames  = $caByAppId[$_.appId]
    $caPoliciesJson = if ($caPolicyNames -and $caPolicyNames.Count -gt 0) { $caPolicyNames | ConvertTo-Json -Compress } else { "[]" }
    $caStatus       = if ($caPolicies.Count -eq 0) { "Unknown" } elseif ($caPolicyNames -and $caPolicyNames.Count -gt 0) { "Covered" } else { "None" }

    $si = Get-SignInFields -AppId $_.appId
    $dssi = if ($si.DaysSinceSignIn -ge 0) { $si.DaysSinceSignIn } else { $null }
    $lsi  = if ($si.LastSignInDate) { $si.LastSignInDate } else { $null }
    $caPoliciesArr = if ($caPolicyNames -and $caPolicyNames.Count -gt 0) { @($caPolicyNames) } else { @() }
    $risk = Get-StaticRisk -Type "enterpriseapp" -Owners $owners -Creds $shapedCr -Roles $roleObjs -Perms $permObjs -DaysSinceSignIn $dssi -IsFirstParty $isFirstParty -CAStatus $caStatus -SSOMode $ssoMode
    # Federation lives on the app registration; a linked SP inherits the advisory via its appId.
    $spFed  = if ($appRegObjIdByAppId.ContainsKey($_.appId) -and $fedByAppObjId.ContainsKey($appRegObjIdByAppId[$_.appId])) { @($fedByAppObjId[$appRegObjIdByAppId[$_.appId]]) } else { @() }
    $advice = if ($isFirstParty -eq "true") { @() } else { Get-Advisories -Type "enterpriseapp" -Creds $shapedCr -FederatedCreds $spFed }
    $shaped = @{
        DisplayName = $_.displayName; AppId = $_.appId; ObjectId = $_.id; CreatedOn = $_.createdDateTime
        Credentials = $shapedCr; Owners = $owners; DirectoryRoles = $roleObjs; ApiPermissions = $permObjs
        MarkedForDeletion = $false; MarkedBy = $null; MarkedOn = $null; ProposedName = $null
        RenameRequestedBy = $null; RenameRequestedOn = $null; NotifyOnExpiry = $false
        ContextPurpose = $null; ContextSystem = $null; ContextEnvironment = $null
        ContextCriticality = $null; ContextUpdatedBy = $null; ContextUpdatedOn = $null
        PendingOwnerChanges = @(); RiskLevel = $risk.Level; RiskReasons = @($risk.Reasons); IdentityType = "enterpriseapp"
        LastSignInDate = $lsi; DaysSinceSignIn = $dssi
        AccountEnabled = [bool]$_.accountEnabled; IsFirstParty = ($isFirstParty -eq "true"); HasLinkedAppReg = ($hasLinkedAppReg -eq "true")
        SSOMode = $ssoMode; CAPolicies = $caPoliciesArr; CAStatus = $caStatus
        Advisories = @($advice); FederatedCredentials = $spFed; HasFederation = ($spFed.Count -gt 0)
    }
    @{
        PartitionKey     = "enterpriseapp"; RowKey = $_.appId
        DisplayName      = $_.displayName; ObjectId = $_.id
        OwnersJson       = $ownersJson; CredsJson = $credsJson; RolesJson = $rolesJson; PermsJson = $permsJson
        HasCredentials   = if ($_.passwordCredentials.Count -gt 0 -or $_.keyCredentials.Count -gt 0) { "true" } else { "false" }
        HasLinkedAppReg  = $hasLinkedAppReg; IsFirstParty = $isFirstParty
        HasFederation    = if ($spFed.Count -gt 0) { "true" } else { "false" }
        AccountEnabled   = if ($_.accountEnabled) { "true" } else { "false" }
        SSOMode          = $ssoMode
        CAPoliciesJson   = $caPoliciesJson; CAStatus = $caStatus
        CreatedOn        = $_.createdDateTime; LastSynced = $now
        LastSignInDate   = $si.LastSignInDate
        DaysSinceSignIn  = $si.DaysSinceSignIn
        SignInSynced     = $si.SignInSynced
        ShapedJson       = Get-ShapedJson $shaped
    }
}
Invoke-BatchUpsert -TableName "IdentityCache" -Entities $spEntities

# ══════════════════════════════════════
# 8. SYNC MANAGED IDENTITIES
# ══════════════════════════════════════
Write-Host "--- Syncing Managed Identities ---"
$miApps = @($allServicePrincipals | Where-Object { $_.servicePrincipalType -eq "ManagedIdentity" })
Write-Host "Processing $($miApps.Count) managed identities"

Clear-Partition -Partition "managedidentity"

$miEntities = $miApps | ForEach-Object {
    $resourceId = ($_.alternativeNames | Where-Object { $_ -match "^/subscriptions/" }) | Select-Object -First 1
    $miType     = if ($_.alternativeNames -contains "isExplicit=True") { "User-assigned" } else { "System-assigned" }
    $roleObjs   = Get-ClassifiedRoles $rolesBySp[$_.id]
    $permObjs   = Get-ClassifiedPerms $permsBySp[$_.id]
    $rolesJson  = if ($roleObjs.Count) { (,$roleObjs | ConvertTo-Json -Compress) } else { "[]" }
    $permsJson  = if ($permObjs.Count) { (,$permObjs | ConvertTo-Json -Compress) } else { "[]" }

    $si = Get-SignInFields -AppId $_.appId
    $dssi = if ($si.DaysSinceSignIn -ge 0) { $si.DaysSinceSignIn } else { $null }
    $lsi  = if ($si.LastSignInDate) { $si.LastSignInDate } else { $null }
    $risk = Get-StaticRisk -Type "managedidentity" -Owners @() -Creds @() -Roles $roleObjs -Perms $permObjs -DaysSinceSignIn $dssi
    $shaped = @{
        DisplayName = $_.displayName; AppId = $_.appId; ObjectId = $_.id; CreatedOn = $_.createdDateTime
        Credentials = @(); Owners = @(); DirectoryRoles = $roleObjs; ApiPermissions = $permObjs
        MarkedForDeletion = $false; MarkedBy = $null; MarkedOn = $null; ProposedName = $null
        RenameRequestedBy = $null; RenameRequestedOn = $null; NotifyOnExpiry = $false
        ContextPurpose = $null; ContextSystem = $null; ContextEnvironment = $null
        ContextCriticality = $null; ContextUpdatedBy = $null; ContextUpdatedOn = $null
        PendingOwnerChanges = @(); RiskLevel = $risk.Level; RiskReasons = @($risk.Reasons); IdentityType = "managedidentity"
        LastSignInDate = $lsi; DaysSinceSignIn = $dssi
        AccountEnabled = [bool]$_.accountEnabled; AzureResourceId = $resourceId; ManagedIdentityType = $miType
        Advisories = @()
    }
    @{
        PartitionKey        = "managedidentity"; RowKey = $_.appId
        DisplayName         = $_.displayName; ObjectId = $_.id
        OwnersJson          = "[]"; CredsJson = "[]"; RolesJson = $rolesJson; PermsJson = $permsJson
        HasCredentials      = "false"; AccountEnabled = if ($_.accountEnabled) { "true" } else { "false" }
        AzureResourceId     = $resourceId; ManagedIdentityType = $miType
        CreatedOn           = $_.createdDateTime; LastSynced = $now
        LastSignInDate      = $si.LastSignInDate
        DaysSinceSignIn     = $si.DaysSinceSignIn
        SignInSynced        = $si.SignInSynced
        ShapedJson          = Get-ShapedJson $shaped
    }
}
Invoke-BatchUpsert -TableName "IdentityCache" -Entities $miEntities

# ══════════════════════════════════════
# 9. PRECOMPUTE DASHBOARD SUMMARY
#    Aggregate all four partitions into a tiny summary row so the portal paints the
#    dashboard cards from one instant read (served by GetTenantConfig) instead of waiting
#    for all four GetIdentities calls. Mirrors the client-side updateDash() math.
#    Wrapped so a failure here never fails the (already-completed) cache sync.
# ══════════════════════════════════════
try {
    Write-Host "--- Computing dashboard summary ---"

    function Read-ShapedPartition { param([string]$Partition)
        $fv = [System.Uri]::EscapeDataString("PartitionKey eq '$Partition'")
        $u  = "${tableBaseUri}IdentityCache()?" + '$filter=' + "$fv&`$select=RowKey,ShapedJson&`$top=1000"
        $acc = @()
        do {
            $resp = Invoke-WebRequest -Method GET -Uri $u -Headers (Get-StorageHeaders) -UseBasicParsing
            $parsed = $resp.Content | ConvertFrom-Json
            foreach ($row in $parsed.value) {
                if (-not $row.ShapedJson) { continue }
                $acc += ($row.ShapedJson | ConvertFrom-Json)
            }
            $np = $resp.Headers["x-ms-continuation-NextPartitionKey"]; if ($np -is [array]) { $np = $np[0] }
            $nr = $resp.Headers["x-ms-continuation-NextRowKey"];       if ($nr -is [array]) { $nr = $nr[0] }
            if (-not [string]::IsNullOrWhiteSpace($np)) { $u = "${tableBaseUri}IdentityCache()?" + '$filter=' + "$fv&`$select=RowKey,ShapedJson&`$top=1000&NextPartitionKey=$np"; if (-not [string]::IsNullOrWhiteSpace($nr)) { $u += "&NextRowKey=$nr" } } else { $u = $null }
        } while ($u)
        return $acc
    }

    $ar = @(Read-ShapedPartition "appregistration")
    # Exclude Microsoft first-party enterprise apps — the portal hides them by default, so
    # the dashboard must too, or the precomputed cards (Total, Privileged, etc.) are inflated
    # by hundreds of Microsoft SPs and disagree with the client's live recompute.
    $ea = @(Read-ShapedPartition "enterpriseapp" | Where-Object { -not $_.IsFirstParty })
    $mi = @(Read-ShapedPartition "managedidentity")
    $pu = @(Read-ShapedPartition "privilegeduser")
    $all = @($ar + $ea + $mi + $pu)
    $tot = $all.Count

    function Test-HasPriv { param($o) (@($o.DirectoryRoles).Count -gt 0) -or (@($o.ApiPermissions | Where-Object { $_.RiskLevel -eq "High" }).Count -gt 0) }
    function Test-IsStale { param($o)
        if (-not $o.LastSignInDate) { return $false }
        if ($null -eq $o.DaysSinceSignIn) { return $false }
        $t = if ($o.IdentityType -eq "privilegeduser") { 60 } elseif ($o.IdentityType -eq "managedidentity") { 90 } else { 180 }
        return ($o.DaysSinceSignIn -ge $t)
    }

    # Ownership scope: app registrations + non-first-party enterprise apps (Microsoft
    # first-party apps are excluded — they aren't expected to carry a tenant owner).
    $ownScope = @($ar + @($ea | Where-Object { -not $_.IsFirstParty }))
    $wo = @($ownScope | Where-Object { @($_.Owners).Count -gt 0 }).Count
    $po = if ($ownScope.Count) { ($wo / $ownScope.Count) * 100 } else { 100 }

    $credScope = @(($ar + @($ea | Where-Object { -not $_.IsFirstParty })) | Where-Object { @($_.Credentials).Count -gt 0 })
    $credOk    = @($credScope | Where-Object { @($_.Credentials | Where-Object { $_.Status -eq "Expired" -or $_.Status -eq "Expiring" }).Count -eq 0 }).Count
    $pc = if ($credScope.Count) { ($credOk / $credScope.Count) * 100 } else { 100 }

    $caScope = @($ea | Where-Object { (-not $_.IsFirstParty) -and $_.SSOMode -and $_.SSOMode -ne "None" -and $_.CAStatus -ne "Unknown" })
    $caCov   = @($caScope | Where-Object { $_.CAStatus -eq "Covered" }).Count
    $pca = if ($caScope.Count) { ($caCov / $caScope.Count) * 100 } else { 100 }

    $staleScope = @((@($ea | Where-Object { (-not $_.IsFirstParty) -and $_.LastSignInDate }) + @($mi | Where-Object { $_.LastSignInDate })))
    $notStale   = @($staleScope | Where-Object { -not (Test-IsStale $_) }).Count
    $pst = if ($staleScope.Count) { ($notStale / $staleScope.Count) * 100 } else { 100 }

    # Weights: ownership 30, credential hygiene 30, CA coverage 20, staleness 20.
    $sc = ($po*0.30)+($pc*0.30)+($pca*0.20)+($pst*0.20)
    $ex = @($all | Where-Object { @($_.Credentials | Where-Object { $_.Status -eq "Expiring" -or $_.Status -eq "Expired" }).Count -gt 0 }).Count
    $pv = @($all | Where-Object { Test-HasPriv $_ }).Count

    $dash = @{
        PartitionKey = "dashboard"; RowKey = "current"
        Total = $tot; OwnershipPct = [math]::Round($po,2); CredPct = [math]::Round($pc,2)
        CaPct = [math]::Round($pca,2); StalePct = [math]::Round($pst,2)
        HealthScore = [math]::Round($sc,2); ExpiringCount = $ex; PrivilegedCount = $pv; LastSynced = $now
    }
    Invoke-BatchUpsert -TableName "TenantConfig" -Entities @($dash)
    Write-Host "Dashboard summary stored: total=$tot score=$([math]::Round($sc,2))"
} catch {
    Write-Warning "Dashboard summary computation failed: $($_.Exception.Message)"
}

Write-Host "=== Sync finished: $($allApps.Count) app registrations, $($entApps.Count) enterprise apps, $($miApps.Count) managed identities ==="