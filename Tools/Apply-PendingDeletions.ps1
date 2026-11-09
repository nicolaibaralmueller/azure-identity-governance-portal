
# Apply-PendingDeletions.ps1
# Deletes identities that have been marked for deletion in the Identity Governance.
# Covers: app registrations, enterprise apps (service principals), managed identities.
# After successful deletion the GovernanceState entry is cleared so the portal reflects the change.

#Requires -Modules Az.Accounts, Az.Resources, AzTable

Get-AzSubscription | Out-GridView -PassThru | Select-AzSubscription
$storageAccount = Get-AzStorageAccount | Out-GridView -PassThru -Title "Select the governance storage account"

$ErrorActionPreference = "Stop"
$ctx           = $storageAccount.Context
$adminUpn      = (Get-AzContext).Account.Id

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

# ── Read GovernanceState: find items marked for deletion ──
$tagsTable  = (Get-AzStorageTable -Name "GovernanceState" -Context $ctx).CloudTable
$markedTags = Get-AzTableRow -Table $tagsTable -PartitionKey "tags" |
    Where-Object { $_.MarkedForDeletion -eq $true -or [string]$_.MarkedForDeletion -eq "true" }

if (-not $markedTags) {
    Write-Host "No items marked for deletion." -ForegroundColor Green
    return
}

# ── Read IdentityCache to resolve type and display name ──
$cacheTable = (Get-AzStorageTable -Name "IdentityCache" -Context $ctx).CloudTable
$identityLookup = @{}
foreach ($itype in @("appregistration", "enterpriseapp", "managedidentity")) {
    foreach ($entry in (Get-AzTableRow -Table $cacheTable -PartitionKey $itype)) {
        $identityLookup[$entry.RowKey] = $entry
    }
}

# ── Build selection grid ──
$candidates = foreach ($tag in $markedTags) {
    $identity = $identityLookup[$tag.RowKey]
    [PSCustomObject]@{
        AppId        = $tag.RowKey
        DisplayName  = if ($identity) { $identity.DisplayName } else { "(not in cache)" }
        IdentityType = if ($identity) { $identity.PartitionKey } else { "unknown" }
        MarkedBy     = $tag.MarkedBy
        MarkedOn     = $tag.MarkedOn
        _tag         = $tag
    }
}

$selected = $candidates | Out-GridView -PassThru -Title "Select identities to DELETE in Entra ID (this is irreversible)"

if (-not $selected) {
    Write-Host "Nothing selected. Exiting." -ForegroundColor Yellow
    return
}

# ── Execute deletions ──
foreach ($item in $selected) {
    Write-Host "Deleting '$($item.DisplayName)' [$($item.IdentityType)] ($($item.AppId))..." -NoNewline

    try {
        switch ($item.IdentityType) {
            "appregistration" {
                $app = Get-AzADApplication -ApplicationId $item.AppId
                if ($app.Count -gt 1) { Write-Error "More than one application found for AppId '$($item.AppId)'." }
                if ($app) { $app | Remove-AzADApplication }
            }
            { $_ -in "enterpriseapp", "managedidentity" } {
                $sp = Get-AzADServicePrincipal -ApplicationId $item.AppId
                if ($sp.Count -gt 1) { Write-Error "More than one service principal found for AppId '$($item.AppId)'." }
                if ($sp) { $sp | Remove-AzADServicePrincipal }
            }
            default {
                Write-Warning " Skipped — unknown identity type '$($item.IdentityType)'."
                continue
            }
        }

        # Remove the entire GovernanceState row — the app no longer exists
        Remove-AzTableRow -Table $tagsTable -Entity $item._tag | Out-Null

        Write-AuditLog -AppId $item.AppId -Entry @{ Action = "delete"; AppName = $item.DisplayName; IdentityType = $item.IdentityType }

        Write-Host " Done." -ForegroundColor Green
    }
    catch {
        Write-Host " FAILED." -ForegroundColor Red
        Write-Warning "  $_"
    }
}
