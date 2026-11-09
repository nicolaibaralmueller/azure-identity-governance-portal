using namespace System.Net
param($Request, $TriggerMetadata)

$callerName = $Request.Headers["X-MS-CLIENT-PRINCIPAL-NAME"]
if ($callerName) { $callerName = [System.Web.HttpUtility]::UrlDecode($callerName) }
if (-not $callerName) { $callerName = "Unknown" }

# Owner-change requests are admin-only — members are view-only (enforced here, not just in the UI).
$caller = Get-Caller -Request $Request
if (-not $caller.IsAdmin) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = '{"error":"This action requires the Governance.Admin role."}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}

$body = $Request.Body
$appId      = $body.appId
$appName    = $body.appName
$action     = $body.action
$targetId   = $body.targetId
$targetUpn  = $body.targetUpn
$targetName = $body.targetName

if (-not $appId -or -not $action -or -not $targetUpn) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = '{"error":"appId, action, and targetUpn required"}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}

# Get Storage token
$storageResource = "https://storage.azure.com/"
$storageTokenUri = "$($env:IDENTITY_ENDPOINT)?resource=$storageResource&api-version=2019-08-01"
$storageTokenResponse = Invoke-RestMethod -Method GET -Uri $storageTokenUri -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }
$storageToken = $storageTokenResponse.access_token

$tableBaseUri = $env:AzureWebJobsStorage__tableServiceUri
if (-not $tableBaseUri.EndsWith("/")) { $tableBaseUri += "/" }

$now = (Get-Date).ToString("o")
$requestId = [Guid]::NewGuid().ToString("N").Substring(0, 12)

# Check for duplicates
$filter = "PartitionKey eq '$appId' and Status eq 'pending' and Action eq '$action' and TargetUpn eq '$targetUpn'"
$encodedFilter = [System.Uri]::EscapeDataString($filter)
$checkUri = "${tableBaseUri}AppOwnerRequests()?`$filter=$encodedFilter"
$checkHeaders = @{ Authorization = "Bearer $storageToken"; Accept = "application/json;odata=nometadata"; "x-ms-version" = "2020-12-06"; "x-ms-date" = (Get-Date).ToUniversalTime().ToString("R") }

try {
    $existing = Invoke-RestMethod -Method GET -Uri $checkUri -Headers $checkHeaders
    if ($existing.value -and $existing.value.Count -gt 0) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Conflict; Body = '{"error":"A pending request already exists for this user and action"}'; Headers = @{ "Content-Type" = "application/json" } })
        return
    }
} catch {}

# Write request
$tableUri = "${tableBaseUri}AppOwnerRequests"
$entity = @{
    PartitionKey = $appId; RowKey = $requestId; AppName = $appName; Action = $action
    TargetId = $targetId; TargetUpn = $targetUpn; TargetName = $targetName
    RequestedBy = $callerName; RequestedOn = $now; Status = "pending"
} | ConvertTo-Json -Depth 5

$entityUri = "$tableUri(PartitionKey='$appId',RowKey='$requestId')"
$headers = @{ Authorization = "Bearer $storageToken"; "Content-Type" = "application/json"; Accept = "application/json;odata=nometadata"; "x-ms-version" = "2020-12-06"; "x-ms-date" = (Get-Date).ToUniversalTime().ToString("R") }

try {
    Invoke-RestMethod -Method PUT -Uri $entityUri -Headers $headers -Body $entity

    # Audit log
    $auditUri = "${tableBaseUri}AuditLog"
    $ticks = [DateTime]::MaxValue.Ticks - [DateTime]::UtcNow.Ticks
    $auditRowKey = "$ticks-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $auditEntity = @{
        PartitionKey = $appId; RowKey = $auditRowKey; Action = "OwnerChangeRequest"
        AppId = $appId; AppName = $appName; PerformedBy = $callerName; Timestamp_ = $now
        Details = "$action owner: $targetName ($targetUpn)"
    } | ConvertTo-Json -Depth 5
    $auditEntityUri = "$auditUri(PartitionKey='$appId',RowKey='$auditRowKey')"
    try { Invoke-RestMethod -Method PUT -Uri $auditEntityUri -Headers @{ Authorization = "Bearer $storageToken"; "Content-Type" = "application/json"; Accept = "application/json;odata=nometadata"; "x-ms-version" = "2020-12-06"; "x-ms-date" = (Get-Date).ToUniversalTime().ToString("R") } -Body $auditEntity } catch {}

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = "{`"status`":`"created`",`"requestId`":`"$requestId`"}"; Headers = @{ "Content-Type" = "application/json" } })
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::InternalServerError; Body = "{`"error`":`"$($_.Exception.Message)`"}"; Headers = @{ "Content-Type" = "application/json" } })
}