<#
.SYNOPSIS
    Validates the complete Identity Governance deployment.

.DESCRIPTION
    Phase 2 - Step 3 of 3 (Manual)
    
    Validates that both Phase 1 (deploy.ps1) and Phase 2 (setup scripts)
    completed successfully by checking all resources, managed identities,
    permissions, and connectivity.

.EXAMPLE
    .\Validate-Deployment.ps1

.NOTES
    No elevated roles needed — read-only checks only.
#>

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Step 3: Validate Deployment" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Load Setup Context
# ============================================================================

$contextPath = Join-Path $PSScriptRoot "_setup-context.json"
if (-not (Test-Path $contextPath)) {
    Write-Host "[ERROR] Setup context not found. Run 'Configure-GraphPermissions.ps1' first." -ForegroundColor Red
    exit 1
}

$ctx = Get-Content $contextPath | ConvertFrom-Json
$results = @()

# ============================================================================
# Helper
# ============================================================================

function Add-Check {
    param([string]$Check, [bool]$Passed, [string]$Detail = "")
    $script:results += [PSCustomObject]@{
        Check  = $Check
        Status = if ($Passed) { "PASS" } else { "FAIL" }
        Detail = $Detail
    }
    $color = if ($Passed) { "Green" } else { "Red" }
    $symbol = if ($Passed) { "[PASS]" } else { "[FAIL]" }
    Write-Host "$symbol $Check" -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor Gray }
}

# ============================================================================
# Phase 1: Azure Resources
# ============================================================================

Write-Host "--- Phase 1: Azure Resources ---" -ForegroundColor White
Write-Host ""

# Function App
$funcName = $ctx.FunctionAppName
$func = Get-AzWebApp -ResourceGroupName $ctx.ResourceGroupName -Name $funcName -ErrorAction SilentlyContinue
Add-Check "Function App exists" ($null -ne $func) $funcName

if ($func) {
    Add-Check "Function App has managed identity" ($null -ne $func.Identity.PrincipalId) $func.Identity.PrincipalId
    Add-Check "Function App is running" ($func.State -eq "Running")
}

# Web App
$webName = $ctx.WebAppName
$web = Get-AzWebApp -ResourceGroupName $ctx.ResourceGroupName -Name $webName -ErrorAction SilentlyContinue
Add-Check "Web App exists" ($null -ne $web) $webName

if ($web) {
    Add-Check "Web App has managed identity" ($null -ne $web.Identity.PrincipalId) $web.Identity.PrincipalId
    Add-Check "Web App is running" ($web.State -eq "Running")

    # Check config.json. Once EasyAuth is enabled the portal redirects anonymous
    # requests to the Microsoft sign-in page, so a plain GET returns the login HTML
    # instead of the file. Detect that (by content) and report "protected" rather
    # than a false failure.
    $cfgUrl = "https://$($web.DefaultHostName)/config.json"
    try {
        $resp = Invoke-WebRequest -Uri $cfgUrl -Method Get -UseBasicParsing -ErrorAction Stop
        $body = "$($resp.Content)"
        if ($body -match '__REPLACED_AT_DEPLOY__') {
            Add-Check "config.json has valid apiBaseUrl" $false "still the placeholder '__REPLACED_AT_DEPLOY__' — re-deploy the portal code"
        } elseif ($body -match '"apiBaseUrl"\s*:\s*"([^"]+)"') {
            Add-Check "config.json has valid apiBaseUrl" $true $Matches[1]
        } elseif ($body -match 'login\.microsoftonline\.com|/\.auth/login|Sign in to your account|Stay signed in') {
            Add-Check "config.json (portal protected by EasyAuth)" $true "Sign-in required — verify apiBaseUrl in a browser while authenticated"
        } else {
            Add-Check "config.json has valid apiBaseUrl" $false "unexpected (non-JSON) response from $cfgUrl"
        }
    } catch {
        Add-Check "config.json accessible" $false $_.Exception.Message
    }
}

# Storage Account (name is generated at deploy time - look it up in the resource group)
$storage = Get-AzStorageAccount -ResourceGroupName $ctx.ResourceGroupName -ErrorAction SilentlyContinue | Select-Object -First 1
Add-Check "Storage Account exists" ($null -ne $storage) $storage.StorageAccountName

# CORS
if ($func -and $web) {
    $funcConfig = Get-AzWebApp -ResourceGroupName $ctx.ResourceGroupName -Name $funcName
    $corsOrigins = $funcConfig.SiteConfig.Cors.AllowedOrigins
    $webOrigin = "https://$($web.DefaultHostName)"
    $corsValid = $corsOrigins -contains $webOrigin
    Add-Check "Function App CORS allows Web App" $corsValid ($corsOrigins -join ", ")
}

Write-Host ""

# ============================================================================
# Phase 2: Entra ID Configuration
# ============================================================================

Write-Host "--- Phase 2: Entra ID (Managed Identity) ---" -ForegroundColor White
Write-Host ""

$managedIdentityId = $ctx.ManagedIdentityId

# Graph API permissions
$graphAppId = "00000003-0000-0000-c000-000000000000"
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"

$appRoles = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentityId -All -ErrorAction SilentlyContinue
$graphRoles = $appRoles | Where-Object { $_.ResourceId -eq $graphSp.Id }

Add-Check "Graph API permissions assigned" ($graphRoles.Count -gt 0) "$($graphRoles.Count) permission(s)"

if ($graphRoles) {
    # Resolve role names
    $graphAppRoles = $graphSp.AppRoles
    foreach ($assignment in $graphRoles) {
        $roleDef = $graphAppRoles | Where-Object { $_.Id -eq $assignment.AppRoleId }
        $roleName = if ($roleDef) { $roleDef.Value } else { $assignment.AppRoleId }
        Add-Check "  Graph permission: $roleName" $true
    }
}

# Directory roles the managed identity belongs to. Query the identity's memberOf
# directly rather than enumerating every role's members — the latter relies on the
# member object's .Id, which the Graph SDK doesn't reliably populate (the id lands in
# AdditionalProperties), so it silently matches nothing. memberOf is keyed on the MI
# and works with the Application.Read.All scope already used above.
$assignedRoles = @(
    Get-MgServicePrincipalMemberOf -ServicePrincipalId $managedIdentityId -All -ErrorAction SilentlyContinue |
        Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.directoryRole' } |
        ForEach-Object { $_.AdditionalProperties.displayName }
)

Add-Check "Directory roles assigned" ($assignedRoles.Count -gt 0) ($assignedRoles -join ", ")

# ============================================================================
# Connectivity Test
# ============================================================================

Write-Host ""
Write-Host "--- Connectivity ---" -ForegroundColor White
Write-Host ""

if ($func) {
    $funcUrl = "https://$($func.DefaultHostName)/api/health"
    try {
        $healthResponse = Invoke-RestMethod -Uri $funcUrl -Method Get -TimeoutSec 10 -ErrorAction Stop
        Add-Check "Function App health endpoint" $true
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 401 -or $_.Exception.Response.StatusCode.value__ -eq 404) {
            Add-Check "Function App responds (no health endpoint)" $true "$($_.Exception.Response.StatusCode.value__)"
        } else {
            Add-Check "Function App reachable" $false $_.Exception.Message
        }
    }
}

if ($web) {
    $webUrl = "https://$($web.DefaultHostName)"
    try {
        $webResponse = Invoke-WebRequest -Uri $webUrl -Method Get -TimeoutSec 10 -ErrorAction Stop
        Add-Check "Web App reachable" ($webResponse.StatusCode -eq 200)
    } catch {
        Add-Check "Web App reachable" $false $_.Exception.Message
    }
}

# ============================================================================
# Summary
# ============================================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Validation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$passed = ($results | Where-Object { $_.Status -eq "PASS" }).Count
$failed = ($results | Where-Object { $_.Status -eq "FAIL" }).Count
$total = $results.Count

if ($failed -eq 0) {
    Write-Host " All $total checks passed!" -ForegroundColor Green
    Write-Host ""
    if ($web) {
        Write-Host " Portal URL: https://$($web.DefaultHostName)" -ForegroundColor Cyan
    }
} else {
    Write-Host " $passed/$total passed, $failed failed" -ForegroundColor Red
    Write-Host ""
    Write-Host " Failed checks:" -ForegroundColor Red
    $results | Where-Object { $_.Status -eq "FAIL" } | ForEach-Object {
        Write-Host "   - $($_.Check)" -ForegroundColor Red
        if ($_.Detail) { Write-Host "     $($_.Detail)" -ForegroundColor Gray }
    }
}

Write-Host "========================================" -ForegroundColor Cyan