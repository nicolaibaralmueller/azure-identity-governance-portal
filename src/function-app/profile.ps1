# profile.ps1 — runs once per PowerShell worker startup; functions defined here are
# available to every function in the app.

# ============================================================================
# Language — T 'key' [args...] returns the text for the deployment's language
# (LANGUAGE app setting, from the Bicep 'language' parameter). Texts live in
# i18n/<code>.psd1; a key missing in the chosen language falls back to English,
# and an unknown key returns the key itself so it shows up in review.
#
# The tables are loaded on first use, not here: the Functions worker does not keep
# variables set in profile.ps1 for the function invocations (only the functions
# survive), so a table loaded at startup is $null by the time T is called.
# ============================================================================
function Initialize-T {
    if ($global:TextEn -and $global:Text) { return }
    $global:LangCode = if ($env:LANGUAGE -in @('en', 'da')) { $env:LANGUAGE } else { 'en' }
    # $PSScriptRoot inside a function is the folder of the script that defined it: the app root.
    $global:TextEn = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'i18n/en.psd1')
    $global:Text   = if ($global:LangCode -eq 'en') { $global:TextEn } else { Import-PowerShellDataFile (Join-Path $PSScriptRoot "i18n/$($global:LangCode).psd1") }
}

function Test-T { param([string]$Key) Initialize-T; return $global:Text.ContainsKey($Key) -or $global:TextEn.ContainsKey($Key) }

function Format-T {
    param([string]$Key, [object[]]$Values)
    Initialize-T
    $fmt = if ($global:Text.ContainsKey($Key)) { $global:Text[$Key] } elseif ($global:TextEn.ContainsKey($Key)) { $global:TextEn[$Key] } else { $Key }
    if ($Values -and $Values.Count -gt 0) { return $fmt -f $Values }
    return $fmt
}

function T {
    param([string]$Key, [Parameter(ValueFromRemainingArguments)][object[]]$Values)
    return Format-T $Key $Values
}

# Singular/plural pick: TN 'mail.days' 3 → 'mail.days.other' formatted with 3 as {0}.
function TN {
    param([string]$Key, [int]$Count, [Parameter(ValueFromRemainingArguments)][object[]]$Values)
    $suffix = if ([math]::Abs($Count) -eq 1) { 'one' } else { 'other' }
    return Format-T "$Key.$suffix" (@($Count) + @($Values))
}

# ============================================================================
# Get-Caller — resolve the signed-in user and their governance role from the
# EasyAuth-injected headers. This is the authorization boundary: GetIdentities and
# the mutating endpoints call it to enforce admin vs member access server-side.
#
# Trust model:
#   - When EasyAuth is enabled it injects X-MS-CLIENT-PRINCIPAL(-NAME) and strips any
#     client-supplied copy, so these headers cannot be spoofed.
#   - When EasyAuth is NOT configured (authClientId empty → public mode), there is no
#     principal header; we treat that as full access so the no-auth deployment still works.
#   - When a principal IS present but carries neither role, access is denied (defense in
#     depth behind "Assignment required = Yes").
# ============================================================================
function Get-Caller {
    param($Request)

    $hdrs = $Request.Headers
    function script:_hdr([string]$name) {
        if ($null -eq $hdrs) { return $null }
        foreach ($k in $hdrs.Keys) {
            if ($k -ieq $name) { $v = $hdrs[$k]; if ($v -is [array]) { $v = $v[0] }; return $v }
        }
        return $null
    }

    $b64 = script:_hdr 'x-ms-client-principal'
    $upn = script:_hdr 'x-ms-client-principal-name'
    $roles = @()

    if ($b64) {
        try {
            $p = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
            $claims = @($p.claims)
            if (-not $upn) {
                $c = $claims | Where-Object { $_.typ -in @('preferred_username', 'name', 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn') } | Select-Object -First 1
                if ($c) { $upn = $c.val }
            }
            $roles = @($claims | Where-Object { $_.typ -eq 'roles' -or $_.typ -eq 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role' } | ForEach-Object { $_.val })
        } catch { }
    }

    $authEnabled = [bool]$b64
    $isAdmin  = (-not $authEnabled) -or ($roles -contains 'Governance.Admin')
    $isMember = ($roles -contains 'Governance.Member') -and -not ($roles -contains 'Governance.Admin')

    return [PSCustomObject]@{
        Upn         = if ($upn) { $upn.ToLower() } else { $null }
        Roles       = $roles
        AuthEnabled = $authEnabled
        IsAdmin     = $isAdmin
        IsMember    = $isMember
        Denied      = ($authEnabled -and -not $isAdmin -and -not $isMember)
    }
}
