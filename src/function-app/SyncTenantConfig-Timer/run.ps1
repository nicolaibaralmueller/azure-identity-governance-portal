param($Timer)

Write-Host "=== Tenant consent config sync started ==="

$graphToken = (Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://graph.microsoft.com&api-version=2019-08-01" -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token
$storageToken = (Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://storage.azure.com/&api-version=2019-08-01" -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token

$gH = @{ Authorization = "Bearer $graphToken" }
$tableBaseUri = $env:AzureWebJobsStorage__tableServiceUri
if (-not $tableBaseUri.EndsWith("/")) { $tableBaseUri += "/" }

$now = (Get-Date).ToString("o")
$findings = @()
$overallStatus = "Healthy"

function Get-WorseStatus {
    param([string]$Current, [string]$Candidate)
    $order = @{ "Healthy" = 0; "Warning" = 1; "Critical" = 2 }
    if ($order[$Candidate] -gt $order[$Current]) { return $Candidate } else { return $Current }
}

# ══════════════════════════════════════
# 1. FETCH AUTHORIZATION POLICY (user consent settings)
#    Requires Policy.Read.All on the managed identity
# ══════════════════════════════════════
$userConsentSetting = "Unknown"
try {
    $authPolicy = Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authorizationPolicy" -Headers $gH
    $permissionGrantPoliciesAssigned = $authPolicy.permissionGrantPoliciesAssigned

    if (-not $permissionGrantPoliciesAssigned -or $permissionGrantPoliciesAssigned.Count -eq 0) {
        $userConsentSetting = "Disabled"
        Write-Host "User consent: Disabled (optimal)"
    } elseif ($permissionGrantPoliciesAssigned -contains "ManagePermissionGrantsForSelf.microsoft-user-default-legacy") {
        $userConsentSetting = "AllowAll"
        $findings += @{ Severity = "Critical"; Setting = "UserConsent"; Message = (T 'consent.userAllowAll') }
        $overallStatus = Get-WorseStatus -Current $overallStatus -Candidate "Critical"
        Write-Host "User consent: AllowAll (critical)"
    } elseif ($permissionGrantPoliciesAssigned | Where-Object { $_ -match "microsoft-user-default-low" }) {
        $userConsentSetting = "VerifiedPublishersOnly"
        $findings += @{ Severity = "Warning"; Setting = "UserConsent"; Message = (T 'consent.userVerified') }
        $overallStatus = Get-WorseStatus -Current $overallStatus -Candidate "Warning"
        Write-Host "User consent: VerifiedPublishersOnly (warning)"
    } else {
        $userConsentSetting = "Restricted"
        Write-Host "User consent: Restricted"
    }
} catch {
    Write-Warning "Could not fetch authorization policy: $($_.Exception.Message)"
    if ($_.Exception.Message -match "403|Forbidden") {
        Write-Warning "Requires Policy.Read.All on the managed identity."
    }
    $userConsentSetting = "Unknown"
    $findings += @{ Severity = "Warning"; Setting = "UserConsent"; Message = (T 'consent.userUnreadable') }
    $overallStatus = Get-WorseStatus -Current $overallStatus -Candidate "Warning"
}

# ══════════════════════════════════════
# 2. FETCH ADMIN CONSENT REQUEST POLICY
# ══════════════════════════════════════
$adminConsentEnabled = "Unknown"
$reviewersConfigured = "Unknown"
$emailNotificationsEnabled = "Unknown"

try {
    $adminConsentPolicy = Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/adminConsentRequestPolicy" -Headers $gH

    $adminConsentEnabled       = if ($adminConsentPolicy.isEnabled) { "true" } else { "false" }
    $reviewersConfigured       = if ($adminConsentPolicy.reviewers -and $adminConsentPolicy.reviewers.Count -gt 0) { "true" } else { "false" }
    $emailNotificationsEnabled = if ($adminConsentPolicy.notifyReviewers) { "true" } else { "false" }

    if ($adminConsentPolicy.isEnabled -eq $false) {
        $findings += @{ Severity = "Critical"; Setting = "AdminConsentRequest"; Message = (T 'consent.adminDisabled') }
        $overallStatus = Get-WorseStatus -Current $overallStatus -Candidate "Critical"
        Write-Host "Admin consent requests: Disabled (critical)"
    } elseif (-not $adminConsentPolicy.reviewers -or $adminConsentPolicy.reviewers.Count -eq 0) {
        $findings += @{ Severity = "Warning"; Setting = "AdminConsentRequest"; Message = (T 'consent.adminNoReviewers') }
        $overallStatus = Get-WorseStatus -Current $overallStatus -Candidate "Warning"
        Write-Host "Admin consent requests: Enabled, no reviewers (warning)"
    } else {
        Write-Host "Admin consent requests: Enabled with reviewers (optimal)"
    }

    if ($adminConsentPolicy.isEnabled -and -not $adminConsentPolicy.notifyReviewers) {
        $findings += @{ Severity = "Warning"; Setting = "EmailNotifications"; Message = (T 'consent.emailOff') }
        $overallStatus = Get-WorseStatus -Current $overallStatus -Candidate "Warning"
        Write-Host "Email notifications: Disabled (warning)"
    }
} catch {
    Write-Warning "Could not fetch admin consent request policy: $($_.Exception.Message)"
    $adminConsentEnabled = "Unknown"
    $findings += @{ Severity = "Warning"; Setting = "AdminConsentRequest"; Message = (T 'consent.adminUnreadable') }
    $overallStatus = Get-WorseStatus -Current $overallStatus -Candidate "Warning"
}

Write-Host "Overall status: $overallStatus, findings: $($findings.Count)"

# ══════════════════════════════════════
# 3. WRITE TO TenantConfig TABLE
# ══════════════════════════════════════
$findingsJson = if ($findings.Count -gt 0) { $findings | ConvertTo-Json -Compress -Depth 5 } else { "[]" }

$configTableUri = "${tableBaseUri}TenantConfig"
$configEntity = @{
    PartitionKey              = "consent"
    RowKey                    = "current"
    UserConsentSetting        = $userConsentSetting
    AdminConsentEnabled       = $adminConsentEnabled
    ReviewersConfigured       = $reviewersConfigured
    EmailNotificationsEnabled = $emailNotificationsEnabled
    OverallStatus             = $overallStatus
    FindingsJson              = $findingsJson
    LastSynced                = $now
} | ConvertTo-Json -Depth 5

$putHeaders = @{
    Authorization  = "Bearer $storageToken"
    "Content-Type" = "application/json"
    Accept         = "application/json;odata=nometadata"
    "x-ms-version" = "2020-12-06"
    "x-ms-date"    = (Get-Date).ToUniversalTime().ToString("R")
    "If-Match"     = "*"
}

try {
    Invoke-RestMethod -Method PUT -Uri "$configTableUri(PartitionKey='consent',RowKey='current')" -Headers $putHeaders -Body $configEntity | Out-Null
    Write-Host "Tenant consent config updated successfully"
} catch {
    # Row does not exist yet - create with POST
    try {
        $postHeaders = @{
            Authorization  = "Bearer $storageToken"
            "Content-Type" = "application/json"
            Accept         = "application/json;odata=nometadata"
            "x-ms-version" = "2020-12-06"
            "x-ms-date"    = (Get-Date).ToUniversalTime().ToString("R")
        }
        Invoke-RestMethod -Method POST -Uri $configTableUri -Headers $postHeaders -Body $configEntity | Out-Null
        Write-Host "Tenant consent config created successfully"
    } catch {
        Write-Warning "Could not write tenant config: $($_.Exception.Message)"
    }
}

Write-Host "=== Tenant consent config sync finished ==="