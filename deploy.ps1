#requires -Version 7.0
<#
.SYNOPSIS
    Deploys the Identity Governance Portal (infrastructure + code) using only the
    Azure CLI (az). No Az PowerShell module required.

.DESCRIPTION
    Runs, from your machine or Azure Cloud Shell:

      1. Ensure the resource group exists
      2. Deploy infrastructure from azResources/main.bicep
      3. Zip-deploy the Function App (API)
      4. Generate config.json with the resolved API URL and language
      5. Zip-deploy the Web App (portal)

    Post-deploy identity setup (RBAC, Microsoft Graph permissions, directory roles and
    the EasyAuth app registration) is NOT done here: run the Setup/ scripts afterwards.
    See docs/setup-guide.md.

    The same steps can be run from any CI/CD system that can run the Azure CLI.

.PARAMETER ResourceGroupName
    Target resource group. Created if it does not exist.

.PARAMETER Location
    Azure region used when creating the resource group. Default: westeurope.

.PARAMETER ParametersFile
    Bicep parameters file. Copy azResources/azuredeploy.parameters.tst.json (or .prd.json) to
    azResources/azuredeploy.parameters.<name>.local.json, fill in real values, and pass it here.
    The *.local.json pattern is git-ignored.

.PARAMETER SubscriptionId
    Optional. Sets the active subscription before deploying.

.PARAMETER CodeOnly
    Skip the infrastructure deployment and only (re)deploy the app code. Resource names are
    read from the previous deployment's outputs.

.PARAMETER WhatIf
    Preview infrastructure changes (az deployment group what-if) and exit.

.EXAMPLE
    az login
    ./deploy.ps1 -ResourceGroupName <RG> -ParametersFile azResources/azuredeploy.parameters.dev.local.json

.EXAMPLE
    # Re-deploy only the Function App + portal code after a code change
    ./deploy.ps1 -ResourceGroupName <RG> -CodeOnly

.EXAMPLE
    # Preview infrastructure changes without deploying
    ./deploy.ps1 -ResourceGroupName <RG> -ParametersFile azResources/azuredeploy.parameters.dev.local.json -WhatIf
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$Location = 'westeurope',
    [string]$ParametersFile,
    [string]$SubscriptionId,
    [switch]$CodeOnly,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$deploymentName = 'identityGovernance'
$bicep   = Join-Path $PSScriptRoot 'azResources/main.bicep'
$funcSrc = Join-Path $PSScriptRoot 'src/function-app'
$webSrc  = Join-Path $PSScriptRoot 'src/web-app'

# Run az and throw on a non-zero exit code so the script stops on failure.
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Quiet)
    if (-not $Quiet) { Write-Host "az $($Arguments -join ' ')" -ForegroundColor DarkGray }
    $out = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed (exit $LASTEXITCODE)" }
    return $out
}

function Test-ParametersFile {
    if (-not $ParametersFile) { throw "Pass -ParametersFile (see Get-Help ./deploy.ps1 -Detailed)." }
    if (-not (Test-Path $ParametersFile)) { throw "Parameters file not found: $ParametersFile" }
    $raw = Get-Content $ParametersFile -Raw
    if ($raw -match '"<[A-Za-z]' -or $raw -match '/<[A-Za-z]' -or $raw -match '00000000-0000-0000-0000-000000000000') {
        throw "Parameters file '$ParametersFile' still contains <placeholder> or all-zero GUID values. " +
              "Copy it to a *.local.json, fill in real values (or remove optional parameters), and pass that file."
    }
}

# --- preflight -------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) not found. Install it: https://learn.microsoft.com/cli/azure/install-azure-cli"
}
if (-not (Test-Path $bicep)) { throw "Bicep template not found: $bicep" }

if ($SubscriptionId) { Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null }
try { Invoke-Az @('account', 'show') -Quiet | Out-Null }
catch { throw "Not logged in to Azure. Run 'az login' first." }

# --- what-if (preview, then exit) ------------------------------------------
if ($WhatIf) {
    Test-ParametersFile
    Invoke-Az @('group', 'create', '-n', $ResourceGroupName, '-l', $Location) | Out-Null
    Invoke-Az @('deployment', 'group', 'what-if', '-g', $ResourceGroupName,
        '--template-file', $bicep, '--parameters', "@$ParametersFile")
    return
}

# --- infrastructure --------------------------------------------------------
if (-not $CodeOnly) {
    Test-ParametersFile

    Write-Host "==> Ensuring resource group '$ResourceGroupName' ($Location)" -ForegroundColor Cyan
    Invoke-Az @('group', 'create', '-n', $ResourceGroupName, '-l', $Location) | Out-Null

    Write-Host "==> Deploying infrastructure (main.bicep)" -ForegroundColor Cyan
    Invoke-Az @('deployment', 'group', 'create', '-g', $ResourceGroupName, '-n', $deploymentName,
        '--template-file', $bicep, '--parameters', "@$ParametersFile") | Out-Null
}

# --- resolve resource names from the deployment outputs --------------------
Write-Host "==> Reading deployment outputs" -ForegroundColor Cyan
$outJson = Invoke-Az @('deployment', 'group', 'show', '-g', $ResourceGroupName, '-n', $deploymentName,
    '--query', 'properties.outputs', '-o', 'json') -Quiet
$outputs = ($outJson -join "`n") | ConvertFrom-Json
$functionAppName = $outputs.functionAppName.value
$webAppName      = $outputs.webAppName.value
$apiBaseUrl      = $outputs.functionAppUrl.value
$portalUrl       = $outputs.portalPublicUrl.value
if (-not $functionAppName -or -not $webAppName) {
    throw "Could not read app names from deployment '$deploymentName'. Run once without -CodeOnly first."
}

# The Bicep 'language' parameter lands as the LANGUAGE app setting; the portal reads the same value.
$language = Invoke-Az @('functionapp', 'config', 'appsettings', 'list', '-g', $ResourceGroupName, '-n', $functionAppName,
    '--query', "[?name=='LANGUAGE'].value | [0]", '-o', 'tsv') -Quiet
if ($language -notin @('en', 'da')) { $language = 'en' }

# --- package + deploy code -------------------------------------------------
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "ig-deploy-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # Function App (API)
    $funcZip = Join-Path $tmp 'functionapp.zip'
    Write-Host "==> Packaging Function App" -ForegroundColor Cyan
    Compress-Archive -Path (Join-Path $funcSrc '*') -DestinationPath $funcZip -Force
    Write-Host "==> Deploying Function App '$functionAppName'" -ForegroundColor Cyan
    Invoke-Az @('functionapp', 'deployment', 'source', 'config-zip',
        '-g', $ResourceGroupName, '-n', $functionAppName, '--src', $funcZip) | Out-Null

    # Web App (portal): stage a copy so config.json is generated without
    # changing the repository's placeholder src/web-app/config.json.
    Write-Host "==> Staging portal and writing config.json (apiBaseUrl=$apiBaseUrl, language=$language)" -ForegroundColor Cyan
    $webStage = Join-Path $tmp 'webapp'
    Copy-Item -Path $webSrc -Destination $webStage -Recurse
    @{ apiBaseUrl = $apiBaseUrl; language = $language } | ConvertTo-Json |
        Set-Content -Path (Join-Path $webStage 'config.json') -Encoding utf8
    $webZip = Join-Path $tmp 'webapp.zip'
    Compress-Archive -Path (Join-Path $webStage '*') -DestinationPath $webZip -Force
    Write-Host "==> Deploying Web App '$webAppName'" -ForegroundColor Cyan
    Invoke-Az @('webapp', 'deployment', 'source', 'config-zip',
        '-g', $ResourceGroupName, '-n', $webAppName, '--src', $webZip) | Out-Null
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- summary ---------------------------------------------------------------
Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host "  Portal : $portalUrl"
Write-Host "  API    : $apiBaseUrl"
Write-Host ""
Write-Host "Next steps on a first deployment (see docs/setup-guide.md):" -ForegroundColor Yellow
Write-Host "  1. Grant the Function App identity Azure RBAC + Microsoft Graph permissions:"
Write-Host "       Setup/Assign-AzureRbac.ps1, Setup/Configure-GraphPermissions.ps1, Setup/Assign-DirectoryRoles.ps1"
Write-Host "  2. Create the Entra app registration for sign-in, set authClientId, and redeploy:"
Write-Host "       Setup/Configure-AuthAppRegistration.ps1"
Write-Host "  3. (Optional) Email notifications: set acsEndpoint + mailSenderAddress, then"
Write-Host "       Setup/Assign-CommunicationServicesRole.ps1"
