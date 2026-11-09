param($Timer)

Write-Host "=== Expiry notification run started ==="

# ── Guard: exit immediately if mail (Azure Communication Services) is not configured ──
$acsEndpoint = "$env:ACS_ENDPOINT".Trim().TrimEnd('/')
$fromAddr    = $env:MAIL_FROM
if ([string]::IsNullOrWhiteSpace($acsEndpoint) -or [string]::IsNullOrWhiteSpace($fromAddr)) {
    Write-Warning "Mail not configured (ACS_ENDPOINT or MAIL_FROM missing). Skipping."
    return
}

$storageToken = (Invoke-RestMethod -Method GET -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://storage.azure.com/&api-version=2019-08-01" -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token
$tableBaseUri = $env:AzureWebJobsStorage__tableServiceUri
if (-not $tableBaseUri.EndsWith("/")) { $tableBaseUri += "/" }

$now   = Get-Date
$nowIso = $now.ToString("o")
$thresholds = @(30, 14, 7, 1)

# Days AFTER expiry at which the loop is escalated. Without these the last thing an owner
# ever hears is "1 day left" — the actual outage arrives unannounced.
$expiredThresholds = @(0, 7)

# Escalation recipients (semicolon/comma separated). These are copied on post-expiry mail
# and are the ONLY recipients when an app has expired credentials and no owner left to tell.
$escalationTo = @()
if (-not [string]::IsNullOrWhiteSpace($env:GOVERNANCE_ESCALATION_TO)) {
    $escalationTo = @($env:GOVERNANCE_ESCALATION_TO -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$portalUrl = $env:PORTAL_URL

# The renewal steps in the mail quote the organisation's own maximum secret lifetime, so the
# advice and the advisory in the portal are driven by the same setting and cannot drift apart.
$secretMaxMonths = if ($env:SECRET_MAX_LIFETIME_DAYS) { [math]::Round([int]$env:SECRET_MAX_LIFETIME_DAYS / 30.4) } else { 12 }

function Get-StorageHeaders {
    return @{
        Authorization  = "Bearer $storageToken"
        Accept         = "application/json;odata=nometadata"
        "x-ms-version" = "2020-12-06"
        "x-ms-date"    = (Get-Date).ToUniversalTime().ToString("R")
    }
}

function Get-AllTableEntities { param([string]$TableName)
    $uri = "${tableBaseUri}${TableName}()?`$top=1000"; $all = @()
    do {
        $h    = Get-StorageHeaders
        try { $resp = Invoke-WebRequest -Method GET -Uri $uri -Headers $h -UseBasicParsing }
        catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                Write-Host "Table '$TableName' does not exist yet — treating as empty."; return @()
            }
            throw
        }
        $parsed = $resp.Content | ConvertFrom-Json; $all += $parsed.value
        $np = $resp.Headers["x-ms-continuation-NextPartitionKey"]; if ($np -is [array]) { $np = $np[0] }
        $nr = $resp.Headers["x-ms-continuation-NextRowKey"];       if ($nr -is [array]) { $nr = $nr[0] }
        if (-not [string]::IsNullOrWhiteSpace($np)) {
            $uri = "${tableBaseUri}${TableName}()?`$top=1000&NextPartitionKey=$np"
            if (-not [string]::IsNullOrWhiteSpace($nr)) { $uri += "&NextRowKey=$nr" }
        } else { $uri = $null }
    } while ($uri); return $all }

function Get-TableEntitiesByPartition { param([string]$TableName, [string]$Partition)
    $tableUri    = "${tableBaseUri}${TableName}"
    $filterValue = [System.Uri]::EscapeDataString("PartitionKey eq '$Partition'")
    $uri         = "$tableUri()?`$filter=$filterValue&`$top=1000"; $all = @()
    do {
        $h    = Get-StorageHeaders
        $resp = Invoke-WebRequest -Method GET -Uri $uri -Headers $h -UseBasicParsing
        $parsed = $resp.Content | ConvertFrom-Json; $all += $parsed.value
        $np = $resp.Headers["x-ms-continuation-NextPartitionKey"]; if ($np -is [array]) { $np = $np[0] }
        $nr = $resp.Headers["x-ms-continuation-NextRowKey"];       if ($nr -is [array]) { $nr = $nr[0] }
        if (-not [string]::IsNullOrWhiteSpace($np)) {
            $uri = "$tableUri()?`$filter=$filterValue&`$top=1000&NextPartitionKey=$np"
            if (-not [string]::IsNullOrWhiteSpace($nr)) { $uri += "&NextRowKey=$nr" }
        } else { $uri = $null }
    } while ($uri); return $all }

# ── Read all governance state and build opt-in lookup ──
Write-Host "Reading GovernanceState..."
$govEntities = Get-AllTableEntities -TableName "GovernanceState"
$notifyLookup = @{}
foreach ($g in $govEntities) {
    if ($g.NotifyOnExpiry -eq "true") { $notifyLookup[$g.RowKey] = $true }
}
Write-Host "Found $($notifyLookup.Count) identities opted in to notifications"

if ($notifyLookup.Count -eq 0) {
    Write-Host "No identities opted in. Exiting."
    return
}

# ── Read NotificationLog to avoid duplicate sends ──
Write-Host "Reading NotificationLog..."
$sentLog = @{}
$logByApp = @{}
$logEntities = Get-AllTableEntities -TableName "NotificationLog"
foreach ($l in $logEntities) {
    # Key: "<appId>|<credKey>|<threshold>"
    $sentLog["$($l.PartitionKey)|$($l.RowKey)"] = $true
    if (-not $logByApp.ContainsKey($l.PartitionKey)) { $logByApp[$l.PartitionKey] = @() }
    $logByApp[$l.PartitionKey] += $l
}
Write-Host "Found $($sentLog.Count) previously sent notification records"

# ── Read IdentityCache for app registrations and enterprise apps ──
Write-Host "Reading IdentityCache..."
$appRegs   = Get-TableEntitiesByPartition -TableName "IdentityCache" -Partition "appregistration"
$entApps   = Get-TableEntitiesByPartition -TableName "IdentityCache" -Partition "enterpriseapp"
$allCacheEntities = $appRegs + $entApps
Write-Host "Loaded $($appRegs.Count) app registrations and $($entApps.Count) enterprise apps"

# Stable per-credential identifier used for dedup. Prefers the Entra keyId (rotating a
# credential yields a new keyId); falls back to a hash of type+name+expiry for cache rows
# written before keyId was captured.
function Get-CredId { param($cred)
    if ($cred.KeyId) { return ([string]$cred.KeyId -replace '[^A-Za-z0-9\-]', '') }
    $raw   = "$($cred.Type)|$($cred.DisplayName)|$($cred.EndDateTime)"
    $md5   = [System.Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
    return (-join ($bytes | ForEach-Object { $_.ToString("x2") }))
}

# ── Build notification jobs: one email per app+threshold, deduped per credential ──
$emailJobs = @()

foreach ($entity in $allCacheEntities) {
    $appId = $entity.RowKey
    if (-not $notifyLookup.ContainsKey($appId)) { continue }

    $creds = if ($entity.CredsJson -and $entity.CredsJson -ne '[]') {
        try { @($entity.CredsJson | ConvertFrom-Json) } catch { @() }
    } else { @() }

    if ($creds.Count -eq 0) { continue }

    $owners = if ($entity.OwnersJson -and $entity.OwnersJson -ne '[]') {
        try { @($entity.OwnersJson | ConvertFrom-Json) } catch { @() }
    } else { @() }

    # Disabled owners are dropped: mailing a departed employee is how an expiry goes unseen.
    # An app whose owners have all left still escalates, just straight to the owner.
    $ownerUpns = @($owners | Where-Object { $_.UserPrincipalName -and $_.Enabled -ne $false } | ForEach-Object { $_.UserPrincipalName })
    if ($ownerUpns.Count -eq 0 -and $escalationTo.Count -eq 0) {
        Write-Host "No active owner and no escalation address for '$($entity.DisplayName)' — nothing to notify"
        continue
    }

    # Deep link to the page where the credential is actually renewed. App registrations
    # (and enterprise apps that have one in this tenant) go to Certificates & secrets;
    # a third-party enterprise app has no app registration here, so its SSO blade — where
    # the SAML signing certificate lives — is the closest equivalent.
    $hasAppReg = ($entity.PartitionKey -eq "appregistration") -or ($entity.HasLinkedAppReg -eq "true")
    $renewUrl  = if ($hasAppReg) {
        "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/$appId/isMSAApp~/false"
    } else {
        "https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/SignOn/objectId/$($entity.ObjectId)/appId/$appId"
    }

    $hasFederation = ($entity.HasFederation -eq "true")

    # ── Pre-expiry warnings (30/14/7/1) ──
    foreach ($threshold in $thresholds) {
        $matchingCreds = @()
        foreach ($cred in $creds) {
            if (-not $cred.EndDateTime) { continue }
            $exp = try { [datetime]$cred.EndDateTime } catch { $null }
            if (-not $exp) { continue }
            $daysLeft = [math]::Floor(($exp - $now).TotalDays)
            # Match exact threshold day (within a 1-day window to handle timer drift)
            if ($daysLeft -ge ($threshold - 1) -and $daysLeft -le $threshold) {
                # Dedup per individual credential, not per app — a freshly rotated
                # credential (new keyId) gets its own notifications even if an older
                # credential on the same app was already notified at this threshold.
                $credId = Get-CredId $cred
                $rowKey = "t$threshold-$credId"
                if ($sentLog.ContainsKey("$appId|$rowKey")) {
                    Write-Host "Already sent $threshold-day notice for credential '$($cred.DisplayName)' on $($entity.DisplayName) — skipping"
                    continue
                }
                $matchingCreds += [PSCustomObject]@{
                    Name     = $cred.DisplayName
                    Type     = $cred.Type
                    Expires  = $exp.ToString("yyyy-MM-dd")
                    DaysLeft = $daysLeft
                    RowKey   = $rowKey
                }
            }
        }
        if ($matchingCreds.Count -eq 0) { continue }
        if ($ownerUpns.Count -eq 0) { continue }   # pre-expiry warnings are for owners only

        $emailJobs += [PSCustomObject]@{
            Kind        = "warning"
            AppId       = $appId
            AppName     = $entity.DisplayName
            OwnerUpns   = $ownerUpns
            Threshold   = $threshold
            Credentials = $matchingCreds
            RenewUrl    = $renewUrl
            HasFederation = $hasFederation
        }
    }

    # ── Post-expiry escalation (day 0 and day +7) ──
    # Owners plus the escalation address, because by this point the owner's silence is
    # itself the problem. Same per-credential dedup, distinct 'x' rowKey namespace.
    foreach ($after in $expiredThresholds) {
        $expiredCreds = @()
        foreach ($cred in $creds) {
            if (-not $cred.EndDateTime) { continue }
            $exp = try { [datetime]$cred.EndDateTime } catch { $null }
            if (-not $exp) { continue }
            $daysOver = [math]::Floor(($now - $exp).TotalDays)
            if ($daysOver -ge $after -and $daysOver -le ($after + 1)) {
                $credId = Get-CredId $cred
                $rowKey = "x$after-$credId"
                if ($sentLog.ContainsKey("$appId|$rowKey")) { continue }
                $expiredCreds += [PSCustomObject]@{
                    Name     = $cred.DisplayName
                    Type     = $cred.Type
                    Expires  = $exp.ToString("yyyy-MM-dd")
                    DaysLeft = -$daysOver
                    RowKey   = $rowKey
                }
            }
        }
        if ($expiredCreds.Count -eq 0) { continue }

        $recipients = @($ownerUpns + $escalationTo | Where-Object { $_ } | Select-Object -Unique)
        if ($recipients.Count -eq 0) { continue }

        $emailJobs += [PSCustomObject]@{
            Kind        = "expired"
            AppId       = $appId
            AppName     = $entity.DisplayName
            OwnerUpns   = $recipients
            Threshold   = $after
            Credentials = $expiredCreds
            RenewUrl    = $renewUrl
            HasFederation = $hasFederation
            Orphaned    = ($ownerUpns.Count -eq 0)
        }
    }

    # ── Renewal confirmation ──
    # A credential we previously warned about that has vanished from the app, while the app
    # still holds a credential valid into the future, was rotated — the loop closed. Say so
    # once and stop, so the owner learns their click actually worked.
    $currentCredIds = @{}
    foreach ($cred in $creds) { $currentCredIds[(Get-CredId $cred)] = $true }
    $hasValidCred = @($creds | Where-Object {
        $e = try { [datetime]$_.EndDateTime } catch { $null }
        $e -and $e -gt $now
    }).Count -gt 0

    if ($hasValidCred -and $ownerUpns.Count -gt 0 -and $logByApp.ContainsKey($appId)) {
        $notifiedIds = @{}
        foreach ($l in $logByApp[$appId]) {
            $dash = ([string]$l.RowKey).IndexOf('-')
            if ($dash -lt 0) { continue }
            $prefix = ([string]$l.RowKey).Substring(0, $dash)
            if ($prefix -eq "renewed") { continue }
            $cid = ([string]$l.RowKey).Substring($dash + 1)
            if (-not $notifiedIds.ContainsKey($cid)) { $notifiedIds[$cid] = $l.CredName }
        }
        $renewed = @()
        foreach ($cid in $notifiedIds.Keys) {
            if ($currentCredIds.ContainsKey($cid)) { continue }          # still there, not renewed
            if ($sentLog.ContainsKey("$appId|renewed-$cid")) { continue } # already confirmed
            $renewed += [PSCustomObject]@{
                Name     = $notifiedIds[$cid]
                Type     = "Secret"
                Expires  = ""
                DaysLeft = 0
                RowKey   = "renewed-$cid"
            }
        }
        if ($renewed.Count -gt 0) {
            $nextExpiry = @($creds | ForEach-Object { try { [datetime]$_.EndDateTime } catch { $null } } | Where-Object { $_ -and $_ -gt $now } | Sort-Object | Select-Object -First 1)
            $emailJobs += [PSCustomObject]@{
                Kind        = "renewed"
                AppId       = $appId
                AppName     = $entity.DisplayName
                OwnerUpns   = $ownerUpns
                Threshold   = 0
                Credentials = $renewed
                RenewUrl    = $renewUrl
                HasFederation = $hasFederation
                NextExpiry  = if ($nextExpiry) { ([datetime]$nextExpiry[0]).ToString("yyyy-MM-dd") } else { "" }
            }
        }
    }
}

Write-Host "Prepared $($emailJobs.Count) notification emails to send"

# ── Email builder ──
function Build-EmailHtml {
    param([string]$AppName, [int]$Threshold, [array]$Credentials, [string]$RenewUrl,
          [string]$Kind = "warning", [bool]$HasFederation = $false, [bool]$Orphaned = $false, [string]$NextExpiry = "",
          [int]$MaxMonths = 12)

    $isExpired = ($Kind -eq "expired")
    $isRenewed = ($Kind -eq "renewed")

    $urgencyColor = if ($isRenewed) { "#5aad28" }
                    elseif ($isExpired) { "#8b1a1a" }
                    elseif ($Threshold -le 1) { "#c0392b" }
                    elseif ($Threshold -le 7) { "#f7a21b" }
                    else { "#5aad28" }
    $urgencyText  = if ($isRenewed -or $isExpired -or $Threshold -le 1) { "#ffffff" } else { "#1a1a1a" }
    $urgencyIcon  = if ($isRenewed) { "&#10003;" } else { "&#9888;" }
    $urgencyLabel = if ($isRenewed) { T 'mail.urgency.renewed' }
                    elseif ($isExpired -and $Threshold -eq 0) { T 'mail.urgency.expiredToday' }
                    elseif ($isExpired) { T 'mail.urgency.expiredDays' $Threshold }
                    elseif ($Threshold -le 1) { T 'mail.urgency.today' }
                    else { T 'mail.urgency.daysLeft' $Threshold }
    $subhead = if ($isRenewed) { T 'mail.subhead.renewed' } else { T 'mail.subhead.expiry' }

    $renewTarget = if ($RenewUrl -match 'RegisteredApps') { T 'mail.renewTarget.appReg' } else { T 'mail.renewTarget.sso' }

    $rowIndex = 0
    $credRows = ($Credentials | ForEach-Object {
        $typeIcon = if ($_.Type -eq "Certificate") { "&#128196;" } else { "&#128273;" }
        $rowBg    = if ($rowIndex % 2 -eq 0) { "#ffffff" } else { "#f9f9f9" }
        $rowIndex++
        $remaining = if ($isRenewed) { T 'mail.remaining.replaced' }
                     elseif ($_.DaysLeft -lt 0) { TN 'mail.daysAgo' ([math]::Abs($_.DaysLeft)) }
                     else { TN 'mail.days' $_.DaysLeft }
        $typeLabel = if (Test-T "cred.$($_.Type)") { T "cred.$($_.Type)" } else { $_.Type }
        "<tr style='background-color:$rowBg'>
          <td style='padding:8px 14px;border-bottom:1px solid #e0e0e0;font-size:13px;color:#1a1a1a'>$typeIcon $typeLabel</td>
          <td style='padding:8px 14px;border-bottom:1px solid #e0e0e0;font-size:13px;color:#1a1a1a'>$(if($_.Name){$_.Name}else{T 'mail.unnamed'})</td>
          <td style='padding:8px 14px;border-bottom:1px solid #e0e0e0;font-size:13px;color:#1a1a1a'>$(if($_.Expires){$_.Expires}else{'&mdash;'})</td>
          <td style='padding:8px 14px;border-bottom:1px solid #e0e0e0;font-size:13px;color:$urgencyColor;font-weight:600'>$remaining</td>
        </tr>"
    }) -join ""

    # ── Lead paragraph, per kind ──
    $leadText = if ($isRenewed) {
        T 'mail.lead.renewed' $(if ($NextExpiry) { T 'mail.lead.renewedUntil' $NextExpiry } else { '' })
    } elseif ($isExpired -and $Orphaned) {
        T 'mail.lead.expiredOrphaned'
    } elseif ($isExpired) {
        T 'mail.lead.expired'
    } else {
        TN 'mail.lead.warning' $Credentials.Count
    }

    # ── Federation nudge: shown only where it changes what the reader should do ──
    $fedBlock = if ($HasFederation -and -not $isRenewed) {
@"
          <table width="100%" cellpadding="0" cellspacing="0" style="margin:18px 0 0;background:#eef5ff;border-left:3px solid #2b79d7">
            <tr><td style="padding:12px 16px">
              <p style="margin:0;font-size:12px;color:#1a3a5c;font-family:Arial,Helvetica,sans-serif">
                $(T 'mail.fed')
              </p>
            </td></tr>
          </table>
"@
    } else { "" }

    # ── CTA: renewal mails get the button; confirmations do not ──
    # Padding sits on the <td> and NOWHERE else. Every client including Outlook's Word engine
    # honours cell padding natively, so there is no mso- hack to double up and no conditional
    # comment that a mail gateway can strip. border-radius is progressive enhancement: rounded
    # where supported, square in Outlook, correct proportions in both.
    # NO margin on this table. Word does not honour table margins — it relocates them onto the
    # first paragraph INSIDE the cell, i.e. on top of the yellow background, which was adding
    # 26px to the button's height in Outlook and made it look mis-proportioned. The spacer row
    # buys the same gap in a way every client renders identically.
    # mso-line-height-rule:exactly additionally stops Word applying its own leading to the
    # label. Both are inert outside Outlook, where the button stays 43px.
    # Trade-off: only the label is clickable, not the surrounding fill. That is the price of a
    # button that renders identically everywhere, and it is the right one here.
    # No whitespace inside the <td>: a stray newline inherits the cell's 16px font and
    # silently inflates the height.
    $ctaBlock = if ($isRenewed) { "" } else {
@"
          <table cellpadding="0" cellspacing="0" border="0" role="presentation">
            <tr><td style="height:26px;line-height:26px;font-size:0">&nbsp;</td></tr>
            <tr><td bgcolor="#0f6cbd" style="padding:14px 26px;border-radius:5px;mso-line-height-rule:exactly;line-height:15px"><a href="$RenewUrl" style="color:#ffffff;font-size:15px;font-weight:700;mso-line-height-rule:exactly;line-height:15px;text-decoration:none;font-family:Arial,Helvetica,sans-serif">$(T 'mail.cta') &nbsp;&#8594;</a></td></tr>
          </table>
          <p style="margin:10px 0 0;font-size:11px;color:#6e6e6e;font-family:Arial,Helvetica,sans-serif">
            $(T 'mail.ctaOpens' $renewTarget)
          </p>
"@
    }

    # ── How to renew ──
    # Ordering, not clicking, is what goes wrong: people create the new secret and delete the
    # old one before the application is actually using the new value. Five lines, in sequence,
    # placed after the button so anyone who already knows can just click and leave.
    $guideBlock = if ($isRenewed) { "" } else {
@"
          <table width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:22px 0 0;border:1px solid #e0e0e0">
            <tr><td style="padding:14px 18px">
              <p style="margin:0 0 10px;font-size:13px;font-weight:700;color:#1a1a1a;font-family:Arial,Helvetica,sans-serif">$(T 'mail.guide.title')</p>
              <p style="margin:0 0 7px;font-size:12px;color:#3a3a3a;font-family:Arial,Helvetica,sans-serif"><strong>1.</strong> $(T 'mail.guide.1' $MaxMonths)</p>
              <p style="margin:0 0 7px;font-size:12px;color:#3a3a3a;font-family:Arial,Helvetica,sans-serif"><strong>2.</strong> $(T 'mail.guide.2')</p>
              <p style="margin:0 0 7px;font-size:12px;color:#3a3a3a;font-family:Arial,Helvetica,sans-serif"><strong>3.</strong> $(T 'mail.guide.3')</p>
              <p style="margin:0 0 7px;font-size:12px;color:#3a3a3a;font-family:Arial,Helvetica,sans-serif"><strong>4.</strong> $(T 'mail.guide.4')</p>
              <p style="margin:0;font-size:12px;color:#3a3a3a;font-family:Arial,Helvetica,sans-serif"><strong>5.</strong> $(T 'mail.guide.5')</p>
            </td></tr>
          </table>
"@
    }

    return @"
<!DOCTYPE html>
<html lang="$(Initialize-T; $global:LangCode)">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f5f5f5;font-family:Arial,Helvetica,sans-serif">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f5f5f5;padding:32px 0">
    <tr><td align="center">
      <table width="600" cellpadding="0" cellspacing="0" style="background:#ffffff">

        <!-- Yellow top stripe -->
        <tr><td style="background:#0f6cbd;height:6px;font-size:0;line-height:0">&nbsp;</td></tr>

        <!-- Header -->
        <tr><td style="background:#ffffff;padding:20px 32px 0 32px;border-bottom:3px solid #0f6cbd">
          <p style="margin:0;color:#1a1a1a;font-size:18px;font-weight:700;font-family:Arial,Helvetica,sans-serif">$(T 'mail.portalName')</p>
          <p style="margin:4px 0 16px;color:#6e6e6e;font-size:12px;font-family:Arial,Helvetica,sans-serif">$subhead</p>
        </td></tr>

        <!-- Urgency banner -->
        <tr><td style="background:$urgencyColor;padding:10px 32px">
          <p style="margin:0;color:$urgencyText;font-size:13px;font-weight:600;font-family:Arial,Helvetica,sans-serif">$urgencyIcon $urgencyLabel</p>
        </td></tr>

        <!-- Body -->
        <tr><td style="padding:24px 32px">
          <p style="margin:0 0 8px;font-size:15px;font-weight:600;color:#1a1a1a;font-family:Arial,Helvetica,sans-serif">$([System.Web.HttpUtility]::HtmlEncode($AppName))</p>
          <p style="margin:0 0 20px;font-size:13px;color:#6e6e6e;font-family:Arial,Helvetica,sans-serif">
            $leadText
          </p>

          <!-- Credential table -->
          <table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;border:1px solid #e0e0e0">
            <tr>
              <th style="padding:10px 14px;text-align:left;font-size:13px;color:#1a1a1a;font-weight:600;text-transform:uppercase;letter-spacing:.5px;background:#ebf3fc;border-bottom:2px solid #0f6cbd;font-family:Arial,Helvetica,sans-serif">$(T 'mail.col.type')</th>
              <th style="padding:10px 14px;text-align:left;font-size:13px;color:#1a1a1a;font-weight:600;text-transform:uppercase;letter-spacing:.5px;background:#ebf3fc;border-bottom:2px solid #0f6cbd;font-family:Arial,Helvetica,sans-serif">$(T 'mail.col.name')</th>
              <th style="padding:10px 14px;text-align:left;font-size:13px;color:#1a1a1a;font-weight:600;text-transform:uppercase;letter-spacing:.5px;background:#ebf3fc;border-bottom:2px solid #0f6cbd;font-family:Arial,Helvetica,sans-serif">$(T 'mail.col.expires')</th>
              <th style="padding:10px 14px;text-align:left;font-size:13px;color:#1a1a1a;font-weight:600;text-transform:uppercase;letter-spacing:.5px;background:#ebf3fc;border-bottom:2px solid #0f6cbd;font-family:Arial,Helvetica,sans-serif">$(T 'mail.col.remaining')</th>
            </tr>
            $credRows
          </table>

$fedBlock
$ctaBlock
$guideBlock

          <p style="margin:20px 0 0;font-size:12px;color:#6e6e6e;font-family:Arial,Helvetica,sans-serif">
            $(T 'mail.why')
          </p>
        </td></tr>

        <!-- Footer -->
        <tr><td style="padding:16px 32px;border-top:1px solid #e0e0e0">
          <p style="margin:0;font-size:11px;color:#6e6e6e;font-family:Arial,Helvetica,sans-serif">$(T 'mail.footer')</p>
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
    param([string[]]$ToAddresses, [string]$Subject, [string]$HtmlBody)

    $toList = @($ToAddresses | Where-Object { $_ -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' } | ForEach-Object { @{ address = $_ } })
    if ($toList.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; MessageId = $null; Error = "No valid recipients" }
    }
    return Invoke-AcsSend -Recipients $toList -Subject $Subject -HtmlBody $HtmlBody
}

# ── Idempotent NotificationLog write (InsertOrReplace). Returns $true only on a
#    confirmed write so the caller can tell whether dedup state was actually persisted. ──
function Write-NotificationLog { param([string]$AppId, [string]$RowKey, $Entity)
    $uri = "${tableBaseUri}NotificationLog(PartitionKey='$AppId',RowKey='$RowKey')"
    $h   = Get-StorageHeaders; $h["Content-Type"] = "application/json"
    # PUT without If-Match = InsertOrReplace: idempotent whether or not the row exists.
    Invoke-RestMethod -Method PUT -Uri $uri -Headers $h -Body ($Entity | ConvertTo-Json -Depth 5) | Out-Null
}

# ── Process jobs ──
$sent = 0; $failed = 0; $logFailed = 0

foreach ($job in $emailJobs) {
    $kind = if ($job.Kind) { $job.Kind } else { "warning" }
    $subject = switch ($kind) {
        "renewed" { T 'mail.subject.renewed' $job.AppName }
        "expired" {
            if ($job.Threshold -eq 0) { T 'mail.subject.expired' $job.AppName }
            else { T 'mail.subject.expiredDays' $job.Threshold $job.AppName }
        }
        default { TN 'mail.subject.warning' $job.Threshold $job.AppName }
    }
    $html = Build-EmailHtml -AppName $job.AppName -Threshold $job.Threshold -Credentials $job.Credentials `
                            -RenewUrl $job.RenewUrl -Kind $kind -HasFederation ([bool]$job.HasFederation) `
                            -Orphaned ([bool]$job.Orphaned) -NextExpiry ([string]$job.NextExpiry) `
                            -MaxMonths $secretMaxMonths

    Write-Host "Sending '$kind' notice (t=$($job.Threshold)) for '$($job.AppName)' ($($job.Credentials.Count) credential(s)) to $($job.OwnerUpns -join ', ')"

    $result = Send-Email -ToAddresses $job.OwnerUpns -Subject $subject -HtmlBody $html

    if (-not $result.Success) {
        Write-Warning "Send failed for '$($job.AppName)' ($kind, t=$($job.Threshold)): $($result.Error)"
        $failed++
        continue
    }

    $sent++
    Write-Host "Sent (MessageId: $($result.MessageId))"

    # Persist one dedup row per credential that was notified. A failure here is logged
    # loudly (not swallowed) because it means the credential may be re-notified on the
    # next run — visible operationally rather than silently causing duplicate emails.
    foreach ($cred in $job.Credentials) {
        $logEntity = @{
            PartitionKey = $job.AppId
            RowKey       = $cred.RowKey
            AppName      = $job.AppName
            Threshold    = $job.Threshold
            CredName     = $cred.Name
            CredType     = $cred.Type
            SentOn       = $nowIso
            SentTo       = ($job.OwnerUpns -join ";")
            MessageId    = $result.MessageId
        }
        try {
            Write-NotificationLog -AppId $job.AppId -RowKey $cred.RowKey -Entity $logEntity
        } catch {
            $logFailed++
            Write-Error "NotificationLog write FAILED for '$($job.AppName)' credential '$($cred.Name)' (rowKey=$($cred.RowKey)): $($_.Exception.Message). This credential may be re-notified next run."
        }
    }

    # Audit log (best effort)
    $ticks       = [DateTime]::MaxValue.Ticks - [DateTime]::UtcNow.Ticks
    $auditRowKey = "$ticks-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $auditEntity = @{
        PartitionKey = $job.AppId
        RowKey       = $auditRowKey
        Action       = switch ($kind) { "renewed" { "renewal-confirmed" } "expired" { "expiry-escalation-sent" } default { "expiry-notification-sent" } }
        AppName      = $job.AppName
        Threshold    = $job.Threshold
        CredCount    = $job.Credentials.Count
        SentTo       = ($job.OwnerUpns -join ";")
        MessageId    = $result.MessageId
        Timestamp_   = $nowIso
    } | ConvertTo-Json -Depth 5
    $ah = Get-StorageHeaders; $ah["Content-Type"] = "application/json"
    $auditUri = "${tableBaseUri}AuditLog(PartitionKey='$($job.AppId)',RowKey='$auditRowKey')"
    try { Invoke-RestMethod -Method PUT -Uri $auditUri -Headers $ah -Body $auditEntity | Out-Null } catch { Write-Warning "Audit write failed for '$($job.AppName)': $($_.Exception.Message)" }
}

Write-Host "=== Notification run complete: $sent sent, $failed failed, $logFailed log-write failures ==="
if ($logFailed -gt 0) { Write-Error "$logFailed NotificationLog write(s) failed — affected credentials may be re-notified on the next run." }