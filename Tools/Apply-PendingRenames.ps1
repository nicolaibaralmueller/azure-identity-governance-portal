
# Apply-PendingRenames.ps1
# Applies rename requests from the Identity Governance to Entra ID.
# Covers: app registrations, enterprise apps, managed identities.
# When renaming an app registration the linked service principal is also renamed, and vice versa.
# After a successful rename the GovernanceState entry is cleared.

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

# ── Read GovernanceState: find items with a proposed rename ──
$tagsTable    = (Get-AzStorageTable -Name "GovernanceState" -Context $ctx).CloudTable
$pendingRenames = Get-AzTableRow -Table $tagsTable -PartitionKey "tags" |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_.ProposedName) }

if (-not $pendingRenames) {
    Write-Host "No pending renames." -ForegroundColor Green
    return
}

# ── Read IdentityCache to resolve type and current display name ──
$cacheTable = (Get-AzStorageTable -Name "IdentityCache" -Context $ctx).CloudTable
$identityLookup = @{}
foreach ($itype in @("appregistration", "enterpriseapp", "managedidentity")) {
    foreach ($entry in (Get-AzTableRow -Table $cacheTable -PartitionKey $itype)) {
        $identityLookup[$entry.RowKey] = $entry
    }
}

# ── Build selection grid ──
$candidates = foreach ($tag in $pendingRenames) {
    $identity = $identityLookup[$tag.RowKey]
    [PSCustomObject]@{
        AppId             = $tag.RowKey
        CurrentName       = if ($identity) { $identity.DisplayName } else { "(not in cache)" }
        ProposedName      = $tag.ProposedName
        IdentityType      = if ($identity) { $identity.PartitionKey } else { "unknown" }
        RequestedBy       = $tag.RenameRequestedBy
        RequestedOn       = $tag.RenameRequestedOn
        HasLinkedSP       = if ($identity) { $identity.HasLinkedSP -eq "true" } else { $false }
        HasLinkedAppReg   = if ($identity) { $identity.HasLinkedAppReg -eq "true" } else { $false }
        _tag              = $tag
    }
}

$selected = $candidates | Out-GridView -PassThru -Title "Select rename requests to apply in Entra ID"

if (-not $selected) {
    Write-Host "Nothing selected. Exiting." -ForegroundColor Yellow
    return
}

# ── Execute renames ──
foreach ($item in $selected) {
    Write-Host "Renaming '$($item.CurrentName)' → '$($item.ProposedName)' [$($item.IdentityType)]..." -NoNewline

    try {
        switch ($item.IdentityType) {
            "appregistration" {
                # Rename the app registration
                Update-AzADApplication -ApplicationId $item.AppId -DisplayName $item.ProposedName

                # Also rename the linked service principal when it exists
                if ($item.HasLinkedSP) {
                    $sp = Get-AzADServicePrincipal -ApplicationId $item.AppId
                    if ($sp) { Update-AzADServicePrincipal -ApplicationId $item.AppId -DisplayName $item.ProposedName }
                }
            }
            { $_ -in "enterpriseapp", "managedidentity" } {
                # Rename the service principal
                Update-AzADServicePrincipal -ApplicationId $item.AppId -DisplayName $item.ProposedName

                # Also rename the linked app registration when it exists
                if ($item.HasLinkedAppReg) {
                    $app = Get-AzADApplication -ApplicationId $item.AppId
                    if ($app) { Update-AzADApplication -ApplicationId $item.AppId -DisplayName $item.ProposedName }
                }
            }
            default {
                Write-Warning " Skipped — unknown identity type '$($item.IdentityType)'."
                continue
            }
        }

        # Clear the rename request from the tag
        $tag = $item._tag
        $tag.ProposedName        = ""
        $tag.RenameRequestedBy   = ""
        $tag.RenameRequestedOn   = ""
        Update-AzTableRow -Table $tagsTable -Entity $tag | Out-Null

        Write-AuditLog -AppId $item.AppId -Entry @{ Action = "rename-applied"; AppName = $item.CurrentName; NewName = $item.ProposedName }

        Write-Host " Done." -ForegroundColor Green
    }
    catch {
        Write-Host " FAILED." -ForegroundColor Red
        Write-Warning "  $_"
    }
}
