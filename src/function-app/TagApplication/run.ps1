using namespace System.Net

param($Request, $TriggerMetadata)

# ── Caller identity from EasyAuth ──
$callerName = $Request.Headers["X-MS-CLIENT-PRINCIPAL-NAME"]
if (-not $callerName) { $callerName = "Unknown" }

$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = '{"error":"No governance role assigned."}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}

# ── Parse body ──
$body    = $Request.Body
$appId   = $body.appId
$appName = $body.appName
$action  = $body.action  # mark | unmark | rename | notify | unnotify | context

if (-not $appId -or -not $action) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = '{"error":"appId and action are required"}'
        Headers    = @{ "Content-Type" = "application/json" }
    })
    return
}

# What a member may do on an identity they own. All of these are *recorded intent* — none
# of them changes anything in Entra ID until an admin runs the Tools/Apply-*.ps1 scripts —
# so self-service here costs nothing in privilege. Ownership is re-checked below against
# the cache; the portal hiding buttons is cosmetic.
#   notify/unnotify — their own expiry mail
#   rename          — proposes a standards-compliant name
#   mark/unmark     — flags their own app for decommissioning
#   context         — describes what the app is for
$memberActions = @("notify", "unnotify", "rename", "mark", "unmark", "context")
if (-not $caller.IsAdmin -and $action -notin $memberActions) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = '{"error":"This action requires the Governance.Admin role."}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}

# ── Storage token via managed identity ──
$storageToken = (Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://storage.azure.com/&api-version=2019-08-01" -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token
$tableBaseUri = $env:AzureWebJobsStorage__tableServiceUri
if (-not $tableBaseUri.EndsWith("/")) { $tableBaseUri += "/" }

$now = [DateTime]::UtcNow.ToString("o")

function Get-StorageHeaders {
    return @{
        Authorization  = "Bearer $storageToken"
        "x-ms-date"    = [DateTime]::UtcNow.ToString("R")
        "x-ms-version" = "2020-12-06"
        Accept         = "application/json;odata=nometadata"
        "Content-Type" = "application/json"
    }
}

# ── GovernanceState: Insert Or Merge ──
# MERGE without an If-Match header is the Table service's InsertOrMerge: it creates the row
# if missing and otherwise merges only the fields sent, so each action sends just its own
# fields. Any failure throws — the caller turns it into a 500 rather than reporting success
# for a change that was never stored.
$govUrl = "${tableBaseUri}GovernanceState(PartitionKey='tags',RowKey='$appId')"

function Invoke-GovMerge { param([hashtable]$Fields)
    $Fields["PartitionKey"] = "tags"
    $Fields["RowKey"]       = $appId
    Invoke-RestMethod -Method MERGE -Uri $govUrl -Headers (Get-StorageHeaders) -Body ($Fields | ConvertTo-Json -Depth 5) -ErrorAction Stop | Out-Null
}

# Does the caller appear as an owner of this identity in the cache? Used to scope a
# member's notify/unnotify to their own app registrations / enterprise apps.
function Test-CallerOwnsIdentity { param([string]$AppId, [string]$Upn)
    if ([string]::IsNullOrWhiteSpace($Upn)) { return $false }
    foreach ($partition in @("appregistration", "enterpriseapp")) {
        try {
            $entity = Invoke-RestMethod -Method GET -Uri "${tableBaseUri}IdentityCache(PartitionKey='$partition',RowKey='$AppId')" -Headers (Get-StorageHeaders)
        } catch { continue }
        if (-not $entity.OwnersJson -or $entity.OwnersJson -eq '[]') { continue }
        $owners = try { @($entity.OwnersJson | ConvertFrom-Json) } catch { @() }
        foreach ($o in $owners) {
            if ($o.UserPrincipalName -and $o.UserPrincipalName.ToLower() -eq $Upn) { return $true }
        }
    }
    return $false
}

if (-not $caller.IsAdmin -and -not (Test-CallerOwnsIdentity -AppId $appId -Upn $caller.Upn)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = '{"error":"You can only change identities you own."}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}

function Write-AuditLog { param([hashtable]$Entry)
    $ticks  = [DateTime]::MaxValue.Ticks - [DateTime]::UtcNow.Ticks
    $rowKey = "$ticks-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $Entry["PartitionKey"] = $appId
    $Entry["RowKey"]       = $rowKey
    $Entry["Timestamp_"]   = $now
    $h = Get-StorageHeaders
    try {
        Invoke-RestMethod -Method POST -Uri "${tableBaseUri}AuditLog" -Headers $h -Body ($Entry | ConvertTo-Json -Depth 5) | Out-Null
    } catch {
        Write-Warning "Audit log write failed: $($_.Exception.Message)"
    }
}

try {
switch ($action) {

    "mark" {
        Invoke-GovMerge -Fields @{ MarkedForDeletion = "true"; MarkedBy = $callerName; MarkedOn = $now }
        Write-AuditLog  -Entry  @{ Action = "mark"; AppName = $appName; PerformedBy = $callerName }
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = (@{ status = "marked"; by = $callerName; date = $now } | ConvertTo-Json)
            Headers    = @{ "Content-Type" = "application/json" }
        })
    }

    "unmark" {
        Invoke-GovMerge -Fields @{ MarkedForDeletion = "false"; MarkedBy = ""; MarkedOn = "" }
        Write-AuditLog  -Entry  @{ Action = "unmark"; AppName = $appName; PerformedBy = $callerName }
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = (@{ status = "unmarked"; by = $callerName } | ConvertTo-Json)
            Headers    = @{ "Content-Type" = "application/json" }
        })
    }

    "rename" {
        $proposedName = $body.proposedName
        if (-not $proposedName) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = '{"error":"proposedName is required for rename action"}'
                Headers    = @{ "Content-Type" = "application/json" }
            })
            return
        }
        Invoke-GovMerge -Fields @{ ProposedName = $proposedName; RenameRequestedBy = $callerName; RenameRequestedOn = $now }
        Write-AuditLog  -Entry  @{ Action = "rename"; AppName = $appName; ProposedName = $proposedName; PerformedBy = $callerName }
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = (@{ status = "rename-requested"; proposedName = $proposedName; by = $callerName; date = $now } | ConvertTo-Json)
            Headers    = @{ "Content-Type" = "application/json" }
        })
    }

    "context" {
        # Owner-supplied description of what the app is for. Free text plus three short
        # classifiers — no expiry, no due date, nothing that turns stale into a task.
        # Truncated because Azure Table string properties cap at 32k and nobody should be
        # writing an essay here.
        function Limit-Text { param($v, [int]$Max) if ($null -eq $v) { return "" } ; $s = [string]$v; if ($s.Length -gt $Max) { return $s.Substring(0, $Max) } ; return $s }

        $ctxPurpose  = Limit-Text $body.purpose     1000
        $ctxSystem   = Limit-Text $body.system      200
        $ctxEnv      = Limit-Text $body.environment 50
        $ctxCrit     = Limit-Text $body.criticality 50

        $allowedEnv  = @("", "PRD", "TST", "DEV", "Shared")
        $allowedCrit = @("", "Business critical", "Important", "Low impact")
        if ($ctxEnv -notin $allowedEnv -or $ctxCrit -notin $allowedCrit) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = '{"error":"environment must be one of PRD/TST/DEV/Shared and criticality one of Business critical/Important/Low impact"}'
                Headers    = @{ "Content-Type" = "application/json" }
            })
            return
        }

        Invoke-GovMerge -Fields @{
            ContextPurpose     = $ctxPurpose
            ContextSystem      = $ctxSystem
            ContextEnvironment = $ctxEnv
            ContextCriticality = $ctxCrit
            ContextUpdatedBy   = $callerName
            ContextUpdatedOn   = $now
        }
        Write-AuditLog -Entry @{ Action = "context"; AppName = $appName; PerformedBy = $callerName; Details = "system=$ctxSystem env=$ctxEnv crit=$ctxCrit" }
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = (@{ status = "context-saved"; by = $callerName; date = $now } | ConvertTo-Json)
            Headers    = @{ "Content-Type" = "application/json" }
        })
    }

    "notify" {
        Invoke-GovMerge -Fields @{ NotifyOnExpiry = "true"; NotifyAddedBy = $callerName; NotifyAddedOn = $now }
        Write-AuditLog  -Entry  @{ Action = "notify-enable"; AppName = $appName; PerformedBy = $callerName }
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = (@{ status = "notify-enabled"; by = $callerName; date = $now } | ConvertTo-Json)
            Headers    = @{ "Content-Type" = "application/json" }
        })
    }

    "unnotify" {
        Invoke-GovMerge -Fields @{ NotifyOnExpiry = "false"; NotifyAddedBy = ""; NotifyAddedOn = "" }
        Write-AuditLog  -Entry  @{ Action = "notify-disable"; AppName = $appName; PerformedBy = $callerName }
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = (@{ status = "notify-disabled"; by = $callerName } | ConvertTo-Json)
            Headers    = @{ "Content-Type" = "application/json" }
        })
    }

    default {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = "{`"error`":`"Unknown action: $action`"}"
            Headers    = @{ "Content-Type" = "application/json" }
        })
    }
}
} catch {
    # The GovernanceState write failed (e.g. missing Storage Table Data Contributor). Report
    # it so the portal shows an error instead of a change that was never stored.
    Write-Error "TagApplication '$action' on $appId failed: $($_.Exception.Message)" -ErrorAction Continue
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ error = "Could not save the change: $($_.Exception.Message)" } | ConvertTo-Json)
        Headers    = @{ "Content-Type" = "application/json" }
    })
}