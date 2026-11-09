param($Timer)

Write-Host "=== Privileged Users sync started ==="

$graphToken = (Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://graph.microsoft.com&api-version=2019-08-01" -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token
$storageToken = (Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://storage.azure.com/&api-version=2019-08-01" -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token

$gH = @{ Authorization = "Bearer $graphToken" }
$tableBaseUri = $env:AzureWebJobsStorage__tableServiceUri
if (-not $tableBaseUri.EndsWith("/")) { $tableBaseUri += "/" }

function Invoke-BatchUpsert {
    param([string]$TableName, [array]$Entities, [string]$Token)
    $tableUri = "$tableBaseUri$TableName"
    $batchSize = 100; $success = 0; $fail = 0
    for ($i = 0; $i -lt $Entities.Count; $i += $batchSize) {
        $batch = $Entities[$i..([Math]::Min($i + $batchSize - 1, $Entities.Count - 1))]
        $batchId = [Guid]::NewGuid().ToString(); $csId = [Guid]::NewGuid().ToString()
        $parts = @("--batch_$batchId", "Content-Type: multipart/mixed; boundary=changeset_$csId", "")
        foreach ($e in $batch) {
            $json = $e | ConvertTo-Json -Depth 5
            $eUri = "$tableUri(PartitionKey='$($e.PartitionKey)',RowKey='$($e.RowKey)')"
            $parts += "--changeset_$csId", "Content-Type: application/http", "Content-Transfer-Encoding: binary", ""
            $parts += "PUT $eUri HTTP/1.1", "Content-Type: application/json", "Accept: application/json;odata=nometadata", "Prefer: return-no-content", "", $json
        }
        $parts += "--changeset_$csId--", "--batch_$batchId--"
        try {
            Invoke-RestMethod -Method POST -Uri "$tableBaseUri`$batch" -Headers @{
                Authorization = "Bearer $Token"; "Content-Type" = "multipart/mixed; boundary=batch_$batchId"
                Accept = "application/json;odata=nometadata"; "x-ms-version" = "2020-12-06"; "x-ms-date" = (Get-Date).ToUniversalTime().ToString("R")
            } -Body ($parts -join "`r`n")
            $success += $batch.Count
        } catch { $fail += $batch.Count; Write-Warning "Batch failed: $($_.Exception.Message)" }
    }
    Write-Host "$TableName upsert: $success ok, $fail failed"
}

$now = (Get-Date).ToString("o")
$nowDt = Get-Date

# ══════════════════════════════════════
# 1. FETCH DIRECTORY ROLE ASSIGNMENTS
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

# ══════════════════════════════════════
# 2. FETCH ALL SERVICE PRINCIPAL IDs (to exclude them)
# ══════════════════════════════════════
Write-Host "--- Fetching service principal IDs ---"
$spIds = @{}
$uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$select=id&`$top=999"
do {
    $r = Invoke-RestMethod -Method GET -Uri $uri -Headers $gH
    foreach ($sp in $r.value) { $spIds[$sp.id] = $true }
    $uri = $r.'@odata.nextLink'
} while ($uri)
Write-Host "Fetched $($spIds.Count) service principal IDs"

# ══════════════════════════════════════
# 3. FILTER TO USER PRINCIPALS ONLY
# ══════════════════════════════════════
$userRoleAssignments = $allRoleAssignments | Where-Object { -not $spIds.ContainsKey($_.principalId) }
Write-Host "Filtered to $($userRoleAssignments.Count) user role assignments"

# Group by user principal ID
$rolesByUser = @{}
foreach ($ra in $userRoleAssignments) {
    $principalId = $ra.principalId
    if (-not $rolesByUser.ContainsKey($principalId)) { $rolesByUser[$principalId] = @() }
    $roleName = if ($ra.roleDefinition) { $ra.roleDefinition.displayName } else { "Unknown Role" }
    $rolesByUser[$principalId] += @{ RoleName = $roleName; RoleId = $ra.roleDefinitionId }
}
Write-Host "Found $($rolesByUser.Count) users with directory roles"

# ══════════════════════════════════════
# 4. FETCH USER DETAILS FOR EACH PRIVILEGED USER
# ══════════════════════════════════════
Write-Host "--- Fetching user details ---"
$userIds = @($rolesByUser.Keys)
$userDetails = @{}

for ($i = 0; $i -lt $userIds.Count; $i += 20) {
    $batch = $userIds[$i..([Math]::Min($i + 19, $userIds.Count - 1))]
    $batchRequests = @(); $idx = 0
    foreach ($uid in $batch) {
        $batchRequests += @{
            id = "$idx"
            method = "GET"
            url = "/users/$uid`?`$select=id,displayName,userPrincipalName,accountEnabled,createdDateTime,jobTitle,department,signInActivity"
        }
        $idx++
    }
    try {
        $batchResponse = Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/`$batch" -Headers @{
            Authorization = "Bearer $graphToken"; "Content-Type" = "application/json"
        } -Body (@{ requests = $batchRequests } | ConvertTo-Json -Depth 5)

        foreach ($resp in $batchResponse.responses) {
            if ($resp.status -eq 200 -and $resp.body) {
                $userDetails[$resp.body.id] = $resp.body
            }
        }
    } catch { Write-Warning "User batch at offset $i failed: $($_.Exception.Message)" }
}
Write-Host "Fetched details for $($userDetails.Count) users"

# ══════════════════════════════════════
# 5. BUILD AND UPSERT PRIVILEGED USER ENTITIES
# ══════════════════════════════════════
Write-Host "--- Syncing privileged users ---"

# High-risk roles
$highRiskRoles = @("Global Administrator", "Privileged Role Administrator", "Exchange Administrator", "SharePoint Administrator", "Application Administrator", "Cloud Application Administrator", "Privileged Authentication Administrator", "Authentication Administrator", "Security Administrator", "User Administrator", "Intune Administrator", "Compliance Administrator")

$entities = foreach ($uid in $rolesByUser.Keys) {
    $user = $userDetails[$uid]
    if (-not $user) { continue }

    $roles = $rolesByUser[$uid]
    # Precompute RiskLevel per role so the read API doesn't reclassify on every request.
    $classifiedRoles = @($roles | ForEach-Object { @{ RoleName = $_.RoleName; RiskLevel = if ($highRiskRoles -contains $_.RoleName) { "High" } else { "Medium" } } })
    $rolesJson = if ($classifiedRoles.Count -gt 0) { $classifiedRoles | ConvertTo-Json -Compress } else { "[]" }

    $hasHighRole = ($classifiedRoles | Where-Object { $_.RiskLevel -eq "High" }).Count -gt 0
    $roleCount = $roles.Count

    # Extract last sign-in — prefer lastSuccessfulSignInDateTime (available since Dec 2023)
    # as it reflects actual successful authentications regardless of interactive vs non-interactive
    $lastSignIn = ""
    if ($user.signInActivity) {
        if ($user.signInActivity.lastSuccessfulSignInDateTime) {
            $lastSignIn = $user.signInActivity.lastSuccessfulSignInDateTime
        } elseif ($user.signInActivity.lastSignInDateTime) {
            $lastSignIn = $user.signInActivity.lastSignInDateTime
        }
    }

    # ── Precompute the shaped object (minus live governance) so GetIdentities is a
    #    thin read: deserialize + governance overlay, no per-request reclassification. ──
    $daysSinceSignIn = $null
    if ($lastSignIn) { try { $daysSinceSignIn = [math]::Floor(($nowDt - [datetime]$lastSignIn).TotalDays) } catch {} }

    $reasons = @()
    $highRoleNames = @($classifiedRoles | Where-Object { $_.RiskLevel -eq "High" } | ForEach-Object { $_.RoleName })
    $noSignIn = $false
    if ($hasHighRole) { $reasons += T 'risk.privRole' ($highRoleNames -join ", ") }
    if (-not $user.accountEnabled) { $reasons += T 'risk.accountDisabledRoles' }
    if ($hasHighRole -and -not $lastSignIn) { $reasons += T 'risk.privNoSignInRecord'; $noSignIn = $true }
    elseif ($daysSinceSignIn -and $daysSinceSignIn -ge 60) { $reasons += T 'risk.privNoSignInDays' $daysSinceSignIn; $noSignIn = $true }
    # Every reason above is High; decided on the conditions, not the (localized) text.
    $riskLevel = if ($hasHighRole -or -not $user.accountEnabled -or $noSignIn) { "High" }
                 elseif ($reasons.Count -gt 0) { "Medium" } else { "Healthy" }

    $shaped = @{
        DisplayName = $user.displayName; AppId = $user.id; ObjectId = $user.id
        UserPrincipalName = $user.userPrincipalName; AccountEnabled = [bool]$user.accountEnabled
        JobTitle = $user.jobTitle; Department = $user.department
        DirectoryRoles = $classifiedRoles; RoleCount = $roleCount; CreatedOn = $user.createdDateTime
        MarkedForDeletion = $false; MarkedBy = $null; MarkedOn = $null; ProposedName = $null
        RenameRequestedBy = $null; RenameRequestedOn = $null; NotifyOnExpiry = $false
        ContextPurpose = $null; ContextSystem = $null; ContextEnvironment = $null
        ContextCriticality = $null; ContextUpdatedBy = $null; ContextUpdatedOn = $null
        Advisories = @()
        RiskLevel = $riskLevel; RiskReasons = @($reasons); IdentityType = "privilegeduser"
        Owners = @(); Credentials = @(); ApiPermissions = @(); PendingOwnerChanges = @()
        LastSignInDate = $lastSignIn; DaysSinceSignIn = $daysSinceSignIn
    }

    @{
        PartitionKey = "privilegeduser"
        RowKey = $user.id
        DisplayName = $user.displayName
        UserPrincipalName = $user.userPrincipalName
        AccountEnabled = if ($user.accountEnabled) { "true" } else { "false" }
        JobTitle = $user.jobTitle
        Department = $user.department
        RolesJson = $rolesJson
        RoleCount = $roleCount
        HasHighRiskRole = if ($hasHighRole) { "true" } else { "false" }
        CreatedOn = $user.createdDateTime
        LastSignInDate = $lastSignIn
        LastSynced = $now
        ShapedJson = ($shaped | ConvertTo-Json -Compress -Depth 6)
    }
}

$entityArray = @($entities)
Write-Host "Processing $($entityArray.Count) privileged users"
Invoke-BatchUpsert -TableName "IdentityCache" -Entities $entityArray -Token $storageToken

Write-Host "=== Privileged Users sync finished: $($entityArray.Count) users ==="