<#
.SYNOPSIS
    Assigns Entra ID directory roles to the Function App managed identity.

.DESCRIPTION
    Phase 2 - Step 2 of 3 (Manual, requires privileged operator)
    
    Assigns directory roles so the Function App managed identity can
    read and manage app registrations, enterprise apps, and managed identities.

.EXAMPLE
    .\Assign-DirectoryRoles.ps1

.NOTES
    Required Entra ID Role: Privileged Role Administrator or Global Administrator
#>

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Step 2: Assign Directory Roles" -ForegroundColor Cyan
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
Write-Host "Function App:        $($ctx.FunctionAppName)" -ForegroundColor Green
Write-Host "Managed Identity ID: $($ctx.ManagedIdentityId)" -ForegroundColor Green

# ============================================================================
# Ensure Graph Connection
# ============================================================================

$context = Get-MgContext
if (-not $context) {
    Write-Host ""
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
    Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory"
    $context = Get-MgContext
}
Write-Host "Connected as: $($context.Account)" -ForegroundColor Green

# ============================================================================
# Define Directory Roles
# ============================================================================
# Adjust these roles to your requirements. Use least privilege.
#
# Common roles for identity governance:
#   Directory Readers                  — Read all directory objects
#   Cloud Application Administrator   — Manage app registrations & enterprise apps
#   Application Administrator         — Full control over app registrations
#
# Find role template IDs:
#   Get-MgDirectoryRoleTemplate | Select DisplayName, Id
# ============================================================================

$directoryRoles = @(
    @{
        DisplayName = "Directory Readers"
        TemplateId  = "88d8e3e3-8f55-4a1e-953a-9b9898b8876b"
        Reason      = "Read directory objects (users, groups, apps, managed identities)"
    }
)

# ============================================================================
# Display Role Summary
# ============================================================================

Write-Host ""
Write-Host "The following directory roles will be assigned to the managed identity:" -ForegroundColor Yellow
Write-Host ""
foreach ($role in $directoryRoles) {
    Write-Host "  - $($role.DisplayName)" -ForegroundColor White
    Write-Host "    Reason: $($role.Reason)" -ForegroundColor Gray
}
Write-Host ""

$confirm = Read-Host "Proceed? (y/n)"
if ($confirm -ne 'y') {
    Write-Host "Aborted." -ForegroundColor Red
    exit 0
}

# ============================================================================
# Assign Directory Roles
# ============================================================================

$managedIdentityId = $ctx.ManagedIdentityId
$failed = 0

foreach ($role in $directoryRoles) {
    Write-Host ""
    Write-Host "Assigning: $($role.DisplayName)..." -ForegroundColor Yellow

    # Ensure the directory role is activated in the tenant
    $directoryRole = Get-MgDirectoryRole -Filter "roleTemplateId eq '$($role.TemplateId)'" -ErrorAction SilentlyContinue

    if (-not $directoryRole) {
        Write-Host "  Activating directory role..." -ForegroundColor Gray
        $directoryRole = New-MgDirectoryRole -RoleTemplateId $role.TemplateId
    }

    # Check if already assigned
    $existingMembers = Get-MgDirectoryRoleMember -DirectoryRoleId $directoryRole.Id -All
    $alreadyAssigned = $existingMembers | Where-Object { $_.Id -eq $managedIdentityId }

    if ($alreadyAssigned) {
        Write-Host "  [SKIP] Already assigned" -ForegroundColor Yellow
    } else {
        try {
            $memberBody = @{
                "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$managedIdentityId"
            }
            New-MgDirectoryRoleMemberByRef -DirectoryRoleId $directoryRole.Id -BodyParameter $memberBody -ErrorAction Stop
            Write-Host "  [OK]   Role assigned" -ForegroundColor Green
        } catch {
            # The membership read above can miss a just-added/replicating member, so the
            # add may come back as a duplicate — that means it's already assigned, not a failure.
            if ("$($_.Exception.Message)" -match 'already exist') {
                Write-Host "  [SKIP] Already assigned" -ForegroundColor Yellow
            } else {
                Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
                $failed++
            }
        }
    }
}

# ============================================================================
# Update Context
# ============================================================================

$ctx | Add-Member -NotePropertyName "DirectoryRolesAssigned" -NotePropertyValue ($failed -eq 0) -Force
$ctx | ConvertTo-Json | Set-Content -Path $contextPath

if ($failed -gt 0) {
    Write-Host ""
    Write-Host "[ERROR] $failed directory role(s) could not be assigned. Re-run after a few minutes, or verify you have the Privileged Role Administrator role." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Directory roles assigned" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next: Run 'Validate-Deployment.ps1'" -ForegroundColor Yellow