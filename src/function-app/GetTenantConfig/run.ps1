using namespace System.Net
param($Request, $TriggerMetadata)

# Members (and unrecognised callers) don't get tenant-wide consent posture or the dashboard
# summary — the portal hides them, and the API must not hand them over either.
$caller = Get-Caller -Request $Request
if ($caller.IsMember -or $caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = '{"OverallStatus":"Unknown","Findings":[],"Dashboard":null}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}

$storageToken = (Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://storage.azure.com/&api-version=2019-08-01" -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token
$tableBaseUri = $env:AzureWebJobsStorage__tableServiceUri
if (-not $tableBaseUri.EndsWith("/")) { $tableBaseUri += "/" }

$uri = "${tableBaseUri}TenantConfig(PartitionKey='consent',RowKey='current')"
$headers = @{
    Authorization  = "Bearer $storageToken"
    Accept         = "application/json;odata=nometadata"
    "x-ms-version" = "2020-12-06"
    "x-ms-date"    = (Get-Date).ToUniversalTime().ToString("R")
}

# Dashboard summary (precomputed by SyncIdentityCache-Timer) — read independently so the
# cards can paint instantly even if the consent row is missing. Absent until the first
# sync writes it, in which case the portal falls back to computing the cards client-side.
$dashboard = $null
try {
    $dEnt = Invoke-RestMethod -Method GET -Uri "${tableBaseUri}TenantConfig(PartitionKey='dashboard',RowKey='current')" -Headers $headers
    $dashboard = [PSCustomObject]@{
        Total           = [int]$dEnt.Total
        OwnershipPct    = [double]$dEnt.OwnershipPct
        CredPct         = [double]$dEnt.CredPct
        CaPct           = [double]$dEnt.CaPct
        StalePct        = [double]$dEnt.StalePct
        HealthScore    = [double]$dEnt.HealthScore
        ExpiringCount   = [int]$dEnt.ExpiringCount
        PrivilegedCount = [int]$dEnt.PrivilegedCount
        LastSynced      = $dEnt.LastSynced
    }
} catch { $dashboard = $null }

try {
    $entity = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers

    $findings = if ($entity.FindingsJson -and $entity.FindingsJson -ne '[]') {
        try { ,@($entity.FindingsJson | ConvertFrom-Json) } catch { ,@() }
    } else { ,@() }

    $result = [PSCustomObject]@{
        UserConsentSetting        = $entity.UserConsentSetting
        AdminConsentEnabled       = [bool]::Parse($entity.AdminConsentEnabled)
        ReviewersConfigured       = [bool]::Parse($entity.ReviewersConfigured)
        EmailNotificationsEnabled = [bool]::Parse($entity.EmailNotificationsEnabled)
        OverallStatus             = $entity.OverallStatus
        Findings                  = $findings
        LastSynced                = $entity.LastSynced
        Dashboard                 = $dashboard
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($result | ConvertTo-Json -Depth 5)
        Headers    = @{ "Content-Type" = "application/json" }
    })
} catch {
    # Consent row doesn't exist yet — still return the dashboard summary if we have it.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ([PSCustomObject]@{ OverallStatus = "Unknown"; Findings = @(); Dashboard = $dashboard } | ConvertTo-Json -Depth 5)
        Headers    = @{ "Content-Type" = "application/json" }
    })
}