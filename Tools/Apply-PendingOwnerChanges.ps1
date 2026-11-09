
# Apply-PendingOwnerChanges.ps1
# Applies pending owner add/remove requests from the Identity Governance to Entra ID.
# Owner changes are applied against app registrations via the Microsoft Graph REST API
# (using the token from the current Az session).
# After a successful change the AppOwnerRequests entry is set to Status = 'completed'.

#Requires -Modules Az.Accounts, Az.Resources, AzTable

Get-AzSubscription | Out-GridView -PassThru | Select-AzSubscription
$storageAccount = Get-AzStorageAccount | Out-GridView -PassThru -Title "Select the governance storage account"

$ErrorActionPreference = "Stop"
$ctx      = $storageAccount.Context
$adminUpn = (Get-AzContext).Account.Id

# ── Audit log helper ──
$auditTable = (Get-AzStorageTable -Name "AuditLog" -Context $ctx).CloudTable
function Write-AuditLog { param([string]$AppId, [hashtable]$Entry)
    $ticks  = [DateTime]::MaxValue.Ticks - [DateTime]::UtcNow.Ticks
    $entity = $Entry + @{
        PartitionKey = $AppId
        RowKey       = "$ticks-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        Timestamp_   = [DateTime]::UtcNow.ToString("o")
        PerformedBy  = $adminUpn
    }
    try { Add-AzTableRow -Table $auditTable -PartitionKey $entity.PartitionKey -RowKey $entity.RowKey -Property $entity | Out-Null }
    catch { Write-Warning "Audit log write failed: $_" }
}

# ── Read AppOwnerRequests: all pending requests ──
$requestsTable   = (Get-AzStorageTable -Name "AppOwnerRequests" -Context $ctx).CloudTable
$pendingRequests = Get-AzTableRow -Table $requestsTable |
    Where-Object { $_.Status -eq "pending" }

if (-not $pendingRequests) {
    Write-Host "No pending owner change requests." -ForegroundColor Green
    return
}

# ── Read IdentityCache to get ObjectId and display names ──
$cacheTable = (Get-AzStorageTable -Name "IdentityCache" -Context $ctx).CloudTable
$identityLookup = @{}
foreach ($itype in @("appregistration", "enterpriseapp", "managedidentity")) {
    foreach ($entry in (Get-AzTableRow -Table $cacheTable -PartitionKey $itype)) {
        $identityLookup[$entry.RowKey] = $entry
    }
}

# ── Build selection grid ──
$candidates = foreach ($req in $pendingRequests) {
    $identity = $identityLookup[$req.PartitionKey]
    [PSCustomObject]@{
        AppId        = $req.PartitionKey
        RequestId    = $req.RowKey
        AppName      = $req.AppName
        IdentityType = if ($identity) { $identity.PartitionKey } else { "unknown" }
        ObjectId     = if ($identity) { $identity.ObjectId } else { $null }
        Action       = $req.Action   # add | remove
        TargetName   = $req.TargetName
        TargetUpn    = $req.TargetUpn
        TargetId     = $req.TargetId  # user ObjectId; may be empty for remove requests
        RequestedBy  = $req.RequestedBy
        RequestedOn  = $req.RequestedOn
        _req         = $req
    }
}

$selected = $candidates | Out-GridView -PassThru -Title "Select owner change requests to apply in Entra ID"

if (-not $selected) {
    Write-Host "Nothing selected. Exiting." -ForegroundColor Yellow
    return
}

# ── Helper: call Microsoft Graph via current Az session token ──
function Invoke-Graph {
    param([string]$Method, [string]$Uri, [hashtable]$Body)
    $params = @{ Method = $Method; Uri = $Uri }
    if ($Body) { $params.Payload = ($Body | ConvertTo-Json -Depth 5) }
    $response = Invoke-AzRestMethod @params
    if ($response.StatusCode -ge 400) {
        $detail = try { ($response.Content | ConvertFrom-Json).error.message } catch { $response.Content }
        throw "Graph API returned $($response.StatusCode): $detail"
    }
    return $response
}

$graphBase = "https://graph.microsoft.com/v1.0"

# ── Execute owner changes ──
foreach ($item in $selected) {
    Write-Host "$($item.Action.ToUpper()) owner '$($item.TargetName)' ($($item.TargetUpn)) on '$($item.AppName)'..." -NoNewline

    try {
        if (-not $item.ObjectId) {
            throw "Could not find ObjectId for app '$($item.AppName)' in identity cache."
        }

        # Resolve the target user's ObjectId if not already stored (common for remove requests)
        $targetOid = $item.TargetId
        if ([string]::IsNullOrWhiteSpace($targetOid)) {
            $user = Get-AzADUser -UserPrincipalName $item.TargetUpn
            if (-not $user) { throw "User '$($item.TargetUpn)' not found in directory." }
            $targetOid = $user.Id
        }

        # Determine Graph resource type
        $resourceType = switch ($item.IdentityType) {
            "appregistration" { "applications" }
            default           { "servicePrincipals" }
        }

        switch ($item.Action) {
            "add" {
                Invoke-Graph -Method POST `
                    -Uri "$graphBase/$resourceType/$($item.ObjectId)/owners/`$ref" `
                    -Body @{ "@odata.id" = "$graphBase/directoryObjects/$targetOid" } | Out-Null
            }
            "remove" {
                Invoke-Graph -Method DELETE `
                    -Uri "$graphBase/$resourceType/$($item.ObjectId)/owners/$targetOid/`$ref" | Out-Null
            }
            default {
                throw "Unknown action '$($item.Action)'."
            }
        }

        # Mark the request as completed
        $req = $item._req
        $req.Status = "completed"
        Update-AzTableRow -Table $requestsTable -Entity $req | Out-Null

        Write-AuditLog -AppId $item.AppId -Entry @{ Action = "owner-$($item.Action)-applied"; AppName = $item.AppName; TargetName = $item.TargetName; TargetUpn = $item.TargetUpn }

        Write-Host " Done." -ForegroundColor Green
    }
    catch {
        Write-Host " FAILED." -ForegroundColor Red
        Write-Warning "  $_"
    }
}
