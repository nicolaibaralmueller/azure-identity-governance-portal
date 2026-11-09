<#
.SYNOPSIS
    Grants the Function App managed identity the role it needs to send notification mail
    through an Azure Communication Services resource (usually a shared one, outside the RG).

.DESCRIPTION
    Manual, requires a privileged operator: Owner or User Access Administrator on the
    Communication Services resource. The infrastructure deploy never assigns roles.

    The mail timers (SendExpiryNotifications-Timer, SendOwnerDigest-Timer) call the ACS Email
    REST API with the Function App's system-assigned managed identity (Microsoft Entra ID), so
    no access key or secret is stored anywhere. This script assigns one role to that identity
    on the Communication Services resource. The resource's endpoint and the sender address are
    set in the parameter file (acsEndpoint, mailSenderAddress).

    Pick a narrow role, e.g. a custom role with only CommunicationServices/Read,
    CommunicationServices/Write and EmailServices/read. If sends fail with 403, use a role that
    also has EmailServices/write, which matches the permissions Microsoft documents
    (https://learn.microsoft.com/azure/communication-services/quickstarts/email/send-email-smtp/smtp-authentication#assign-a-role-to-the-microsoft-entra-application).
    The broad built-in 'Communication and Email Service Owner' also works but grants far more.
    The script never creates a role; it stops if the role doesn't exist.

    Idempotent: an existing assignment is reported and skipped. Supports -WhatIf.

.PARAMETER ResourceGroupName
    Resource group of the Function App.

.PARAMETER FunctionAppName
    Name of the Function App (API), e.g. "<App>-api-prd".

.PARAMETER CommunicationServiceResourceId
    Resource ID of the Communication Services resource. Find it with:
    az resource list --name <acs-name> --resource-type Microsoft.Communication/communicationServices --query "[0].id" -o tsv

.PARAMETER RoleName
    Name of an existing role to assign (built-in or custom), e.g. a custom
    'Communication Service Mail Sender' role.

.EXAMPLE
    .\Assign-CommunicationServicesRole.ps1 -ResourceGroupName <RG> -FunctionAppName <FunctionAppName> `
        -CommunicationServiceResourceId /subscriptions/<Subscription>/resourceGroups/<RG>/providers/Microsoft.Communication/communicationServices/<acs-name> `
        -RoleName 'Communication Service Mail Sender' -WhatIf

.NOTES
    Requires the Az.Accounts, Az.Resources and Az.Websites modules, and Connect-AzAccount.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $true)]
    [string]$CommunicationServiceResourceId,

    [Parameter(Mandatory = $true)]
    [string]$RoleName
)

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Assign Communication Services role to Function App MI" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Get-AzContext)) {
    Write-Host "[ERROR] No Azure context. Run Connect-AzAccount first." -ForegroundColor Red
    exit 1
}

# ── Function App identity (in the current subscription) ──
$app = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction SilentlyContinue
if (-not $app) {
    Write-Host "[ERROR] Function App '$FunctionAppName' not found in '$ResourceGroupName' (subscription $((Get-AzContext).Subscription.Id))." -ForegroundColor Red
    exit 1
}
$principalId = $app.Identity.PrincipalId
if (-not $principalId) {
    Write-Host "[ERROR] '$FunctionAppName' has no system-assigned managed identity. Deploy the infrastructure first." -ForegroundColor Red
    exit 1
}
Write-Host "Function App MI : $FunctionAppName ($principalId)" -ForegroundColor Green

# ── Communication Services resource (may live in another subscription) ──
$acsSubscriptionId = ($CommunicationServiceResourceId -split '/')[2]
$originalContext = Get-AzContext
if ($acsSubscriptionId -and $acsSubscriptionId -ne $originalContext.Subscription.Id) {
    $null = Set-AzContext -Subscription $acsSubscriptionId
}
try {
    if (-not (Get-AzResource -ResourceId $CommunicationServiceResourceId -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] Communication Services resource not found: $CommunicationServiceResourceId" -ForegroundColor Red
        exit 1
    }
    Write-Host "ACS resource    : $CommunicationServiceResourceId" -ForegroundColor Green

    if (-not (Get-AzRoleDefinition -Name $RoleName -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] Role '$RoleName' not found in subscription $acsSubscriptionId. Pass -RoleName with an existing role." -ForegroundColor Red
        exit 1
    }
    Write-Host "Role            : $RoleName" -ForegroundColor Green
    Write-Host "Reason          : send credential-expiry notifications and the monthly owner digest" -ForegroundColor Gray
    Write-Host ""

    $existing = Get-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $RoleName -Scope $CommunicationServiceResourceId -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -eq $CommunicationServiceResourceId }
    if ($existing) {
        Write-Host "[OK] Already assigned - skipping." -ForegroundColor Green
    } elseif ($PSCmdlet.ShouldProcess($CommunicationServiceResourceId, "Assign '$RoleName' to $FunctionAppName")) {
        # A new identity may not have replicated through Entra yet, so retry rather than fail.
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                $null = New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $RoleName -Scope $CommunicationServiceResourceId -ObjectType 'ServicePrincipal'
                Write-Host "[OK] Assigned." -ForegroundColor Green
                break
            } catch {
                if ($attempt -eq 5) { throw }
                Write-Host "  Retry $attempt : $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Yellow
                Start-Sleep -Seconds 10
            }
        }
    }
} finally {
    if ((Get-AzContext).Subscription.Id -ne $originalContext.Subscription.Id) { $null = Set-AzContext -Context $originalContext }
}

Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host "  1. Make sure acsEndpoint and mailSenderAddress are set in azuredeploy.parameters.<env>.json and redeploy." -ForegroundColor Gray
Write-Host "  2. Role assignments can take a few minutes; then restart the Function App." -ForegroundColor Gray
Write-Host "  3. Trigger SendExpiryNotifications-Timer (Code + Test -> Test/Run) and check the log for 'Sent (MessageId: ...)'." -ForegroundColor Gray
