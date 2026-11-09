<#
.SYNOPSIS
    Creates a throwaway app registration with several secrets expiring at the
    notification thresholds, so the credential-expiry email can be tested quickly.

.DESCRIPTION
    Creates an Entra ID app registration, adds one client secret per threshold (default
    30/14/7/1 days), assigns an owner (so the notification has a recipient), and optionally
    flips the notification opt-in on directly in the GovernanceState table.

    Each secret's endDateTime is set to (now + threshold days). At the next notification
    run the timer computes daysLeft = floor(expiry - now); these land inside the matching
    windows ([29,30], [13,14], [6,7], [0,1]) so every threshold produces one email.

    AFTER running this, for an immediate test (instead of waiting for 08:00 UTC):
      1. Trigger SyncIdentityCache-Timer  — so the new secrets land in IdentityCache.
      2. Trigger SendExpiryNotifications-Timer — sends the emails.
    Both can be run from the Portal (Function -> Code + Test -> Run) or the admin endpoint.

    No company-specific values are hardcoded — all inputs are parameters and the owner
    defaults to the signed-in user.

.PARAMETER DisplayName
    Display name for the test app registration. A timestamp suffix is appended to keep it unique.

.PARAMETER Thresholds
    Day-offsets to create secrets for. Default: 30, 14, 7, 1 (the notifier's thresholds).

.PARAMETER OwnerUpn
    UPN of the directory user to set as owner (the email recipient). Defaults to the signed-in user.

.PARAMETER EnableNotifications
    Also write the GovernanceState opt-in row (NotifyOnExpiry=true) so you don't have to
    toggle it in the portal. Requires -StorageAccountName and -ResourceGroupName, and the
    caller needs 'Storage Table Data Contributor' on the storage account.

.PARAMETER StorageAccountName
    Governance storage account name (required with -EnableNotifications).

.PARAMETER ResourceGroupName
    Resource group of the storage account (required with -EnableNotifications).

.EXAMPLE
    .\New-TestExpiryApp.ps1

.EXAMPLE
    .\New-TestExpiryApp.ps1 -OwnerUpn "ops@contoso.com" -EnableNotifications `
        -StorageAccountName "stidgovprd" -ResourceGroupName "rg-idgov-prd"

.NOTES
    Requires: Az.Accounts, Az.Resources, Az.Storage. Connect with Connect-AzAccount first.
    This creates a REAL app registration — delete it when done (Apply-PendingDeletions.ps1
    or Remove-AzADApplication).
#>

param(
    [string]$DisplayName = "ZZ-Test-Expiry-Notification",
    [int[]] $Thresholds  = @(30, 14, 7, 1),
    [string]$OwnerUpn,
    [switch]$EnableNotifications,
    [string]$StorageAccountName,
    [string]$ResourceGroupName
)

$ErrorActionPreference = 'Stop'
$graph = "https://graph.microsoft.com/v1.0"

# ── Connection check ──
$ctx = Get-AzContext
if (-not $ctx) { Write-Host "[ERROR] Not connected. Run Connect-AzAccount first." -ForegroundColor Red; exit 1 }
Write-Host "Subscription: $($ctx.Subscription.Name)" -ForegroundColor Green

if ($EnableNotifications -and (-not $StorageAccountName -or -not $ResourceGroupName)) {
    Write-Host "[ERROR] -EnableNotifications requires -StorageAccountName and -ResourceGroupName." -ForegroundColor Red
    exit 1
}

# ── Helper: call Graph through the Az session token ──
function Invoke-Graph { param([string]$Method, [string]$Uri, $Body)
    $params = @{ Method = $Method; Uri = $Uri }
    if ($Body) { $params.Payload = ($Body | ConvertTo-Json -Depth 6) }
    $resp = Invoke-AzRestMethod @params
    if ($resp.StatusCode -ge 400) {
        $msg = try { ($resp.Content | ConvertFrom-Json).error.message } catch { $resp.Content }
        throw "Graph $Method $Uri -> $($resp.StatusCode): $msg"
    }
    if ($resp.Content) { return ($resp.Content | ConvertFrom-Json) }
    return $null
}

# ── Resolve the owner (default: signed-in user) ──
if ($OwnerUpn) {
    $owner = Invoke-Graph -Method GET -Uri "$graph/users/$([uri]::EscapeDataString($OwnerUpn))"
} else {
    $owner = Invoke-Graph -Method GET -Uri "$graph/me"
}
if (-not $owner.id) { throw "Could not resolve owner object id." }
if (-not $owner.userPrincipalName) { Write-Warning "Owner has no UPN — the notifier will skip the app (no recipient)." }
Write-Host "Owner: $($owner.displayName) <$($owner.userPrincipalName)>" -ForegroundColor Green

# ── Create the app registration ──
$uniqueName = "$DisplayName-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
Write-Host ""
Write-Host "Creating app registration '$uniqueName'..." -ForegroundColor Yellow
$app = Invoke-Graph -Method POST -Uri "$graph/applications" -Body @{ displayName = $uniqueName }
Write-Host "[OK]   AppId $($app.appId)  (objectId $($app.id))" -ForegroundColor Green

# ── Assign the owner ──
Invoke-Graph -Method POST -Uri "$graph/applications/$($app.id)/owners/`$ref" -Body @{ "@odata.id" = "$graph/directoryObjects/$($owner.id)" } | Out-Null
Write-Host "[OK]   Owner assigned." -ForegroundColor Green

# ── Add one secret per threshold ──
Write-Host ""
Write-Host "Adding $($Thresholds.Count) secrets..." -ForegroundColor Yellow
foreach ($t in $Thresholds) {
    $end = (Get-Date).ToUniversalTime().AddDays($t).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $cred = Invoke-Graph -Method POST -Uri "$graph/applications/$($app.id)/addPassword" -Body @{
        passwordCredential = @{ displayName = "Test-secret-$t-day"; endDateTime = $end }
    }
    Write-Host ("  [OK] {0,-18} expires {1}  (keyId {2})" -f "Test-secret-$t-day", $end, $cred.keyId) -ForegroundColor Green
}

# ── Optionally enable notifications via GovernanceState ──
if ($EnableNotifications) {
    Write-Host ""
    Write-Host "Enabling notifications (GovernanceState opt-in)..." -ForegroundColor Yellow

    $sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
    $tableEndpoint = $sa.PrimaryEndpoints.Table
    if (-not $tableEndpoint.EndsWith("/")) { $tableEndpoint += "/" }

    $tokenResp = Get-AzAccessToken -ResourceUrl "https://storage.azure.com/"
    $storageToken = if ($tokenResp.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new("", $tokenResp.Token).Password
    } else { $tokenResp.Token }

    $entity = @{
        PartitionKey   = "tags"
        RowKey         = $app.appId
        NotifyOnExpiry = "true"
        NotifyAddedBy  = ($owner.userPrincipalName)
        NotifyAddedOn  = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json

    $headers = @{
        Authorization  = "Bearer $storageToken"
        "x-ms-date"    = [DateTime]::UtcNow.ToString("R")
        "x-ms-version" = "2020-12-06"
        Accept         = "application/json;odata=nometadata"
        "Content-Type" = "application/json"
    }
    # PUT without If-Match = InsertOrReplace.
    $url = "${tableEndpoint}GovernanceState(PartitionKey='tags',RowKey='$($app.appId)')"
    try {
        Invoke-RestMethod -Method PUT -Uri $url -Headers $headers -Body $entity | Out-Null
        Write-Host "[OK]   NotifyOnExpiry=true written to GovernanceState." -ForegroundColor Green
    } catch {
        Write-Host "[ERROR] GovernanceState write failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "        (Need 'Storage Table Data Contributor' on $StorageAccountName.)" -ForegroundColor Yellow
    }
}

# ── Summary ──
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Test app created" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Name : $uniqueName"
Write-Host "  AppId: $($app.appId)"
Write-Host ""
Write-Host "Next steps for an immediate test:" -ForegroundColor Yellow
if (-not $EnableNotifications) {
    Write-Host "  1. Enable the Notify toggle for this app in the portal (or re-run with -EnableNotifications)." -ForegroundColor Gray
    Write-Host "  2. Trigger SyncIdentityCache-Timer, then SendExpiryNotifications-Timer." -ForegroundColor Gray
} else {
    Write-Host "  1. Trigger SyncIdentityCache-Timer (so the secrets land in IdentityCache)." -ForegroundColor Gray
    Write-Host "  2. Trigger SendExpiryNotifications-Timer (sends the emails)." -ForegroundColor Gray
}
Write-Host ""
Write-Host "Clean up when done:  Remove-AzADApplication -ApplicationId $($app.appId)" -ForegroundColor Gray
