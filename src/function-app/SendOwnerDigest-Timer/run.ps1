param($Timer)

# ============================================================================
# Per-owner monthly digest
#
# One mail per person, listing the apps they own and what needs attention. This is
# deliberately NOT an attestation: there is nothing to sign off, no due date, and no
# state to maintain — it is a regular touchpoint that costs the owner nothing when
# everything is fine.
#
# For exactly that reason it only goes out when there IS something to say. A monthly
# "nothing to do" mail is how a digest trains people to ignore it.
#
# Scope: identities with NotifyOnExpiry enabled, and nothing else. The per-app toggle is
# the one switch governing every mail this portal sends, so an owner who wants silence
# gets it by switching notifications off — there is no separate opt-out to discover.
# ============================================================================

Write-Host "=== Owner digest run started ==="

$acsEndpoint = "$env:ACS_ENDPOINT".Trim().TrimEnd('/')
$fromAddr    = $env:MAIL_FROM
if ([string]::IsNullOrWhiteSpace($acsEndpoint) -or [string]::IsNullOrWhiteSpace($fromAddr)) {
    Write-Warning "Mail not configured (ACS_ENDPOINT or MAIL_FROM missing). Skipping."
    return
}

$storageToken = (Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://storage.azure.com/&api-version=2019-08-01" -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token
$tableBaseUri = $env:AzureWebJobsStorage__tableServiceUri
if (-not $tableBaseUri.EndsWith("/")) { $tableBaseUri += "/" }

$now       = Get-Date
$nowIso    = $now.ToString("o")
$period    = $now.ToString("yyyyMM")
$portalUrl = $env:PORTAL_URL
$horizon   = 90   # days ahead an expiry is worth mentioning

function Get-StorageHeaders {
    return @{
        Authorization  = "Bearer $storageToken"
        Accept         = "application/json;odata=nometadata"
        "x-ms-version" = "2020-12-06"
        "x-ms-date"    = (Get-Date).ToUniversalTime().ToString("R")
    }
}

function Get-TablePage { param([string]$Url)
    $all = @(); $uri = $Url
    do {
        try { $resp = Invoke-WebRequest -Method GET -Uri $uri -Headers (Get-StorageHeaders) -UseBasicParsing }
        catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                Write-Host "Table not found — treating as empty."; return @()
            }
            throw
        }
        $all += ($resp.Content | ConvertFrom-Json).value
        $np = $resp.Headers["x-ms-continuation-NextPartitionKey"]; if ($np -is [array]) { $np = $np[0] }
        $nr = $resp.Headers["x-ms-continuation-NextRowKey"];       if ($nr -is [array]) { $nr = $nr[0] }
        if (-not [string]::IsNullOrWhiteSpace($np)) {
            $uri = $Url + "&NextPartitionKey=$np"
            if (-not [string]::IsNullOrWhiteSpace($nr)) { $uri += "&NextRowKey=$nr" }
        } else { $uri = $null }
    } while ($uri)
    return $all
}

function Get-ShapedPartition { param([string]$Partition)
    $fv = [System.Uri]::EscapeDataString("PartitionKey eq '$Partition'")
    $url = "${tableBaseUri}IdentityCache()?" + '$filter=' + "$fv&`$select=RowKey,ShapedJson&`$top=1000"
    $acc = @()
    foreach ($row in (Get-TablePage -Url $url)) {
        if (-not $row.ShapedJson) { continue }
        try { $acc += ($row.ShapedJson | ConvertFrom-Json) } catch { }
    }
    return $acc
}

# Notify opt-in lives in GovernanceState, not the cache. It is the single switch governing
# ALL mail from this portal: an app with notifications off generates none — no expiry
# warning, no escalation, and no line in this digest.
$notifyOn = @{}
foreach ($g in (Get-TablePage -Url "${tableBaseUri}GovernanceState()?`$select=RowKey,NotifyOnExpiry&`$top=1000")) {
    if ($g.NotifyOnExpiry -eq "true") { $notifyOn[$g.RowKey] = $true }
}
Write-Host "$($notifyOn.Count) identities have notifications enabled"

if ($notifyOn.Count -eq 0) {
    Write-Host "No identities opted in to notifications. Nothing to digest."
    return
}

# ── Load the estate, scoped to opted-in identities only ──
$identities = @(@(Get-ShapedPartition "appregistration") + @(Get-ShapedPartition "enterpriseapp" | Where-Object { -not $_.IsFirstParty }) |
                Where-Object { $notifyOn.ContainsKey($_.AppId) })
Write-Host "Loaded $($identities.Count) identities with notifications enabled"

# Already sent this period? (Idempotent if the timer fires twice.)
$alreadySent = @{}
foreach ($l in (Get-TablePage -Url "${tableBaseUri}NotificationLog()?`$filter=PartitionKey%20eq%20'digest'&`$top=1000")) {
    $alreadySent[$l.RowKey] = $true
}

# ── Group by owner (enabled owners only — a departed owner gets no mail) ──
$byOwner = @{}
foreach ($id in $identities) {
    foreach ($o in @($id.Owners)) {
        if (-not $o.UserPrincipalName) { continue }
        if ($o.Enabled -eq $false) { continue }
        $upn = $o.UserPrincipalName.ToLower()
        if (-not $byOwner.ContainsKey($upn)) { $byOwner[$upn] = @{ Name = $o.DisplayName; Apps = @() } }
        $byOwner[$upn].Apps += $id
    }
}
Write-Host "Digest scope: $($byOwner.Count) distinct owners"

function Get-CredSummary { param($id)
    $creds = @($id.Credentials)
    if ($creds.Count -eq 0) { return $null }
    $soonest = $null
    foreach ($c in $creds) {
        if ($null -eq $c.DaysLeft) { continue }
        if ($null -eq $soonest -or $c.DaysLeft -lt $soonest.DaysLeft) { $soonest = $c }
    }
    return $soonest
}

function Build-DigestHtml {
    param([string]$OwnerName, [array]$Rows, [int]$TotalApps, [int]$SoleOwnerCount)

    $rowIndex = 0
    $tableRows = ($Rows | ForEach-Object {
        $rowBg = if ($rowIndex % 2 -eq 0) { "#ffffff" } else { "#f9f9f9" }
        $rowIndex++
        $color = switch ($_.Severity) { "danger" { "#c0392b" } "warn" { "#b7791f" } default { "#6e6e6e" } }
        "<tr style='background-color:$rowBg'>
          <td style='padding:8px 14px;border-bottom:1px solid #e0e0e0;font-size:13px;color:#1a1a1a'>$([System.Web.HttpUtility]::HtmlEncode($_.AppName))</td>
          <td style='padding:8px 14px;border-bottom:1px solid #e0e0e0;font-size:13px;color:$color;font-weight:600'>$($_.Status)</td>
          <td style='padding:8px 14px;border-bottom:1px solid #e0e0e0;font-size:12px;color:#6e6e6e'>$($_.Note)</td>
        </tr>"
    }) -join ""

    $soleBlock = if ($SoleOwnerCount -gt 0) {
@"
          <table width="100%" cellpadding="0" cellspacing="0" style="margin:18px 0 0;background:#fff7e6;border-left:3px solid #b7791f">
            <tr><td style="padding:12px 16px">
              <p style="margin:0;font-size:12px;color:#5c4611;font-family:Arial,Helvetica,sans-serif">
                $(TN 'digest.sole' $SoleOwnerCount)
              </p>
            </td></tr>
          </table>
"@
    } else { "" }

    # Padding on the <td> only, and no table margin — see the same block in
    # SendExpiryNotifications-Timer for why the spacer row replaces it.
    $portalBlock = if ($portalUrl) {
@"
          <table cellpadding="0" cellspacing="0" border="0" role="presentation">
            <tr><td style="height:26px;line-height:26px;font-size:0">&nbsp;</td></tr>
            <tr><td bgcolor="#0f6cbd" style="padding:14px 26px;border-radius:5px;mso-line-height-rule:exactly;line-height:15px"><a href="$portalUrl" style="color:#ffffff;font-size:15px;font-weight:700;mso-line-height-rule:exactly;line-height:15px;text-decoration:none;font-family:Arial,Helvetica,sans-serif">$(T 'digest.cta') &nbsp;&#8594;</a></td></tr>
          </table>
"@
    } else { "" }

    return @"
<!DOCTYPE html>
<html lang="$(Initialize-T; $global:LangCode)">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f5f5f5;font-family:Arial,Helvetica,sans-serif">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f5f5f5;padding:32px 0">
    <tr><td align="center">
      <table width="600" cellpadding="0" cellspacing="0" style="background:#ffffff">

        <tr><td style="background:#0f6cbd;height:6px;font-size:0;line-height:0">&nbsp;</td></tr>

        <tr><td style="background:#ffffff;padding:20px 32px 0 32px;border-bottom:3px solid #0f6cbd">
          <p style="margin:0;color:#1a1a1a;font-size:18px;font-weight:700;font-family:Arial,Helvetica,sans-serif">$(T 'mail.portalName')</p>
          <p style="margin:4px 0 16px;color:#6e6e6e;font-size:12px;font-family:Arial,Helvetica,sans-serif">$(T 'digest.subhead')</p>
        </td></tr>

        <tr><td style="padding:24px 32px">
          <p style="margin:0 0 8px;font-size:15px;font-weight:600;color:#1a1a1a;font-family:Arial,Helvetica,sans-serif">$(T 'digest.hello' ([System.Web.HttpUtility]::HtmlEncode($OwnerName)))</p>
          <p style="margin:0 0 20px;font-size:13px;color:#6e6e6e;font-family:Arial,Helvetica,sans-serif">
            $(TN 'digest.own' $TotalApps)
            $(TN 'digest.need' $Rows.Count $horizon)
            $(T 'digest.rest')
          </p>

          <table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;border:1px solid #e0e0e0">
            <tr>
              <th style="padding:10px 14px;text-align:left;font-size:13px;color:#1a1a1a;font-weight:600;text-transform:uppercase;letter-spacing:.5px;background:#ebf3fc;border-bottom:2px solid #0f6cbd;font-family:Arial,Helvetica,sans-serif">$(T 'digest.col.app')</th>
              <th style="padding:10px 14px;text-align:left;font-size:13px;color:#1a1a1a;font-weight:600;text-transform:uppercase;letter-spacing:.5px;background:#ebf3fc;border-bottom:2px solid #0f6cbd;font-family:Arial,Helvetica,sans-serif">$(T 'digest.col.status')</th>
              <th style="padding:10px 14px;text-align:left;font-size:13px;color:#1a1a1a;font-weight:600;text-transform:uppercase;letter-spacing:.5px;background:#ebf3fc;border-bottom:2px solid #0f6cbd;font-family:Arial,Helvetica,sans-serif">$(T 'digest.col.detail')</th>
            </tr>
            $tableRows
          </table>
$soleBlock
$portalBlock

          <p style="margin:20px 0 0;font-size:12px;color:#6e6e6e;font-family:Arial,Helvetica,sans-serif">
            $(T 'digest.why')
          </p>
        </td></tr>

        <tr><td style="padding:16px 32px;border-top:1px solid #e0e0e0">
          <p style="margin:0;font-size:11px;color:#6e6e6e;font-family:Arial,Helvetica,sans-serif">$(T 'digest.footer')</p>
        </td></tr>

      </table>
    </td></tr>
  </table>
</body>
</html>
"@
}

# ── Send via Azure Communication Services Email (REST API, Microsoft Entra ID) ──
# The Function App's managed identity holds a mail-sender role on the Communication Services
# resource (Setup/Assign-CommunicationServicesRole.ps1), so no key or secret is stored.
# Returns a result object { Success; MessageId; Error }. MessageId is the ACS operation ID,
# which identifies the message in the resource's email logs. The sender's display name is
# configured on the sender address in the Email Communication Services domain, not per message.
$acsToken = $null
function Get-AcsToken {
    if (-not $script:acsToken) {
        $script:acsToken = (Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://communication.azure.com&api-version=2019-08-01" -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token
    }
    return $script:acsToken
}

function Invoke-AcsSend {
    param([object[]]$Recipients, [string]$Subject, [string]$HtmlBody)

    $payload = @{
        senderAddress                  = $fromAddr
        recipients                     = @{ to = $Recipients }
        content                        = @{ subject = $Subject; html = $HtmlBody }
        userEngagementTrackingDisabled = $true
    } | ConvertTo-Json -Depth 10

    # ACS applies per-minute/per-hour send limits per domain. A 429 is retried after the
    # Retry-After interval instead of being counted as a failure.
    for ($attempt = 1; ; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Method POST -Uri "$acsEndpoint/emails:send?api-version=2023-03-31" -Headers @{
                Authorization  = "Bearer $(Get-AcsToken)"
                "Content-Type" = "application/json; charset=utf-8"
            } -Body $payload -UseBasicParsing

            $msgId = $null; try { $msgId = ($resp.Content | ConvertFrom-Json).id } catch {}
            $ok    = ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300)
            return [PSCustomObject]@{ Success = $ok; MessageId = $msgId; Error = if ($ok) { $null } else { "HTTP $($resp.StatusCode)" } }
        } catch {
            $status = $null; try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            if ($status -eq 429 -and $attempt -lt 4) {
                $wait = 60; try { $ra = $_.Exception.Response.Headers.RetryAfter.Delta; if ($ra) { $wait = [math]::Ceiling($ra.TotalSeconds) } } catch {}
                Write-Warning "ACS throttled the send (429); retrying in $wait s (attempt $attempt)"
                Start-Sleep -Seconds $wait
                continue
            }
            # ACS returns a JSON error body ({ error: { code, message } }) describing the problem — surface it.
            $detail = $null
            try { $detail = $_.ErrorDetails.Message } catch {}
            return [PSCustomObject]@{ Success = $false; MessageId = $null; Error = "$($_.Exception.Message) $detail".Trim() }
        }
    }
}

function Send-Email {
    param([string]$ToAddress, [string]$Subject, [string]$HtmlBody)
    if ($ToAddress -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        return [PSCustomObject]@{ Success = $false; MessageId = $null; Error = "Invalid recipient '$ToAddress'" }
    }
    return Invoke-AcsSend -Recipients @(@{ address = $ToAddress }) -Subject $Subject -HtmlBody $HtmlBody
}

# ── Build and send ──
$sent = 0; $skipped = 0; $failed = 0

foreach ($upn in $byOwner.Keys) {
    $logKey = "$period-$($upn -replace '[\\/#?]', '_')"
    if ($alreadySent.ContainsKey($logKey)) { Write-Host "Digest already sent to $upn for $period — skipping"; $skipped++; continue }

    $entry = $byOwner[$upn]
    $apps  = @($entry.Apps)
    $rows  = @(); $soleOwner = 0

    foreach ($app in $apps) {
        $liveOwners = @($app.Owners | Where-Object { $_.Enabled -ne $false })
        $isSole     = ($liveOwners.Count -le 1)
        if ($isSole) { $soleOwner++ }

        $hasCreds = @($app.Credentials).Count -gt 0
        $cred = Get-CredSummary $app
        $notes = @()
        $severity = "info"; $status = $null; $onlyOwnerRow = $false

        if ($cred -and $null -ne $cred.DaysLeft) {
            if ($cred.DaysLeft -lt 0) {
                $status = T 'digest.status.expired'; $severity = "danger"
                $notes += TN 'mail.daysAgo' ([math]::Abs($cred.DaysLeft))
            }
            elseif ($cred.DaysLeft -le $horizon) {
                $status = TN 'digest.status.expiresIn' $cred.DaysLeft
                $severity = if ($cred.DaysLeft -le 30) { "danger" } else { "warn" }
            }
        }
        if (-not $status -and $isSole -and $hasCreds) { $status = T 'digest.status.onlyOwner'; $onlyOwnerRow = $true; $severity = "warn"; $notes += T 'digest.note.noSecondOwner' }
        if (-not $status) { continue }   # nothing worth the owner's time on this app

        if ($isSole -and -not $onlyOwnerRow) { $notes += T 'digest.note.onlyOwner' }
        foreach ($a in @($app.Advisories)) { $notes += $a }

        $rows += [PSCustomObject]@{
            AppName  = $app.DisplayName
            Status   = $status
            Severity = $severity
            Note     = ($notes -join "; ")
        }
    }

    if ($rows.Count -eq 0) { Write-Host "Nothing actionable for $upn — no digest sent"; $skipped++; continue }

    $rows = @($rows | Sort-Object @{ Expression = { switch ($_.Severity) { "danger" { 0 } "warn" { 1 } default { 2 } } } }, AppName)
    $ownerName = if ($entry.Name) { $entry.Name } else { $upn }
    $html      = Build-DigestHtml -OwnerName $ownerName -Rows $rows -TotalApps $apps.Count -SoleOwnerCount $soleOwner
    $subject   = TN 'digest.subject' $rows.Count

    Write-Host "Sending digest to $upn ($($rows.Count) of $($apps.Count) apps flagged)"
    $result = Send-Email -ToAddress $upn -Subject $subject -HtmlBody $html

    if (-not $result.Success) {
        Write-Warning "Digest send failed for ${upn}: $($result.Error)"
        $failed++
        continue
    }
    $sent++

    $logEntity = @{
        PartitionKey = "digest"; RowKey = $logKey
        OwnerUpn = $upn; Period = $period; AppCount = $apps.Count; FlaggedCount = $rows.Count
        SentOn = $nowIso; MessageId = $result.MessageId
    }
    $h = Get-StorageHeaders; $h["Content-Type"] = "application/json"
    try {
        Invoke-RestMethod -Method PUT -Uri "${tableBaseUri}NotificationLog(PartitionKey='digest',RowKey='$logKey')" -Headers $h -Body ($logEntity | ConvertTo-Json -Depth 5) | Out-Null
    } catch {
        Write-Error "Digest log write FAILED for ${upn}: $($_.Exception.Message). They may receive a duplicate if this timer runs again this month."
    }
}

Write-Host "=== Owner digest complete: $sent sent, $skipped skipped, $failed failed ==="
