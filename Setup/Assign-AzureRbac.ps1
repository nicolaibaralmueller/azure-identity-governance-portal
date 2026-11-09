<#
.SYNOPSIS
    Grants the Azure RBAC data-plane roles the Function App managed identity needs.

.DESCRIPTION
    Phase 1.5 - Run AFTER the first infrastructure deploy, BEFORE the app is expected
    to work (Manual, requires a privileged operator).

    The deploying principal typically only has Contributor, which cannot write role
    assignments (Microsoft.Authorization/roleAssignments/write), so these grants are
    not in the Bicep template. This script assigns them to the Function App's
    system-assigned managed identity:

      - Storage Table Data Contributor  (storage account)  — portal application tables
      - Storage Blob Data Owner         (storage account)  — identity-based AzureWebJobsStorage host storage
      - Monitoring Metrics Publisher    (app insights)     — Entra-authenticated telemetry ingestion
                                                             (needed once disableAppInsightsLocalAuth=true)

    Until this runs, the Function App cannot start, because AzureWebJobsStorage uses
    an identity-based connection that requires Storage Blob Data Owner. Monitoring
    Metrics Publisher must be in place before local (instrumentation-key) auth is
    disabled on the App Insights component (disableAppInsightsLocalAuth).

.PARAMETER ResourceGroupName
    Resource group where the resources are deployed.

.PARAMETER FunctionAppName
    Name of the Function App (API), e.g. "<App>-api-dev".

.PARAMETER StorageAccountName
    Storage account name. Optional — if omitted, the single storage account in the
    resource group is used.

.PARAMETER AppInsightsName
    Application Insights component name. Optional — if omitted, the single component in
    the resource group is used.

.EXAMPLE
    .\Assign-AzureRbac.ps1 -ResourceGroupName "<RG>" -FunctionAppName "<FunctionAppName>"

.NOTES
    Required Azure role: Owner, or User Access Administrator / Role Based Access Control
    Administrator on the resource group (permission to write role assignments).
    Requires the Az PowerShell module and an active Connect-AzAccount session.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $false)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $false)]
    [string]$AppInsightsName
)

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Assign Azure RBAC to Function App MI" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Prerequisites
# ============================================================================

if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
    Write-Host "[ERROR] Az module not found. Install with: Install-Module Az -Scope CurrentUser" -ForegroundColor Red
    exit 1
}

if (-not (Get-AzContext)) {
    Write-Host "Connecting to Azure..." -ForegroundColor Yellow
    Connect-AzAccount | Out-Null
}

# ============================================================================
# Resolve the Function App managed identity
# ============================================================================

$functionApp = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction SilentlyContinue
if (-not $functionApp) {
    Write-Host "[ERROR] Function App '$FunctionAppName' not found in '$ResourceGroupName'. Run the infrastructure deploy first." -ForegroundColor Red
    exit 1
}

$principalId = $functionApp.Identity.PrincipalId
if (-not $principalId) {
    Write-Host "[ERROR] Function App has no system-assigned managed identity." -ForegroundColor Red
    exit 1
}
Write-Host "Function App identity (principalId): $principalId" -ForegroundColor Green

# ============================================================================
# Resolve target resources
# ============================================================================

if (-not $StorageAccountName) {
    $sa = @(Get-AzStorageAccount -ResourceGroupName $ResourceGroupName)
    if ($sa.Count -ne 1) {
        Write-Host "[ERROR] Expected exactly one storage account in '$ResourceGroupName' (found $($sa.Count)). Pass -StorageAccountName." -ForegroundColor Red
        exit 1
    }
    $StorageAccountName = $sa[0].StorageAccountName
}
$storage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
Write-Host "Storage account: $StorageAccountName" -ForegroundColor Green

if (-not $AppInsightsName) {
    $ai = @(Get-AzApplicationInsights -ResourceGroupName $ResourceGroupName)
    if ($ai.Count -ne 1) {
        Write-Host "[ERROR] Expected exactly one Application Insights component in '$ResourceGroupName' (found $($ai.Count)). Pass -AppInsightsName." -ForegroundColor Red
        exit 1
    }
    $AppInsightsName = $ai[0].Name
}
$appInsights = Get-AzApplicationInsights -ResourceGroupName $ResourceGroupName -Name $AppInsightsName
Write-Host "Application Insights: $AppInsightsName" -ForegroundColor Green

# ============================================================================
# Assign roles (idempotent)
# ============================================================================

function Add-RoleAssignment {
    param([string]$RoleName, [string]$Scope)
    $existing = Get-AzRoleAssignment -ObjectId $principalId -Scope $Scope -RoleDefinitionName $RoleName -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -eq $Scope }
    if ($existing) {
        Write-Host "[SKIP] $RoleName — already assigned" -ForegroundColor Yellow
        return
    }
    try {
        New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $RoleName -Scope $Scope -ObjectType 'ServicePrincipal' | Out-Null
        Write-Host "[OK]   $RoleName" -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] $RoleName — $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Add-RoleAssignment -RoleName "Storage Table Data Contributor" -Scope $storage.Id
Add-RoleAssignment -RoleName "Storage Blob Data Owner"        -Scope $storage.Id
Add-RoleAssignment -RoleName "Monitoring Metrics Publisher"   -Scope $appInsights.Id

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Azure RBAC assigned" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Role assignments can take a few minutes to propagate. Restart the Function App" -ForegroundColor Yellow
Write-Host "if it failed to start before the roles were in place." -ForegroundColor Yellow
