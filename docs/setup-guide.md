# Deployment guide

Step-by-step deployment to an Azure subscription with [`deploy.ps1`](../deploy.ps1) and the Azure CLI. The same steps can be run from any CI/CD system that can run the Azure CLI.

Deployment is **two phases**: `deploy.ps1` deploys infrastructure + code with Contributor rights on the resource group; a privileged operator then grants the permissions Contributor cannot (see [security.md](security.md) for why). Background on the components is in [architecture.md](architecture.md).

## What gets deployed

| Resource | Notes |
|---|---|
| Storage account (+ 6 tables) | `IdentityCache`, `AppOwnerRequests`, `AuditLog`, `GovernanceState`, `NotificationLog`, `TenantConfig` |
| Function App (`*-api-*`) | PowerShell 7.6, Linux, Always On |
| Web App (`*-portal-*`) | Static portal, Linux/Node |
| App Service plan (shared) | **One B2 Linux plan** hosts both apps |
| Application Insights | Linked to a central Log Analytics workspace, or a dedicated one |
| Key Vault (optional, off by default) | Only for secrets you add by hand (`deployKeyVault`) |

## Prerequisites

- An Azure subscription and a resource group name, e.g. `rg-idgov-dev` (`deploy.ps1` creates it if missing).
- For Phase 1: PowerShell 7+ and the **Azure CLI** (`az`), signed in with **Contributor** on the resource group (or the subscription, to create it).
- For Phase 2, on the operator's workstation: PowerShell 7+ with the **`Az`** and **`Microsoft.Graph`** modules, and the **Azure CLI** (`az`).
- **Owner / User Access Administrator** on the RG (for RBAC) and **Privileged Role Administrator** in Entra (for Graph/directory roles + creating the app-registration secret).

> `Connect-AzAccount` (Az PowerShell) and `az` (Azure CLI) keep **separate** logins/subscriptions. Run `az account set --subscription <id>` before `az` commands and `Connect-AzAccount`/`Set-AzContext` before the `*-Az*` cmdlets.

---

## Step 1 — Configure the environment

Copy one of the example parameter files to a git-ignored local file and fill it in: `azuredeploy.parameters.tst.json` is a minimal starting point, `azuredeploy.parameters.prd.json` shows every option (Front Door, IP restrictions, mail, managed-identity sign-in). Remove optional parameters you don't use.

```powershell
Copy-Item azResources/azuredeploy.parameters.tst.json azResources/azuredeploy.parameters.dev.local.json
```

```json
{
  "parameters": {
    "appName":     { "value": "idgov" },
    "environment": { "value": "dev" },
    "logAnalyticsWorkspaceId": { "value": "" },
    "authClientId": { "value": "" }
  }
}
```

- `appName` / `environment` — resources are named `<appName>-api-<environment>`, `<appName>-portal-<environment>` and so on. `environment` is one of `dev`, `tst`, `acc`, `prd`.
- `logAnalyticsWorkspaceId` — a central workspace resource ID, or `""` to create a dedicated one.
- `authClientId` — **leave empty for the first run** (filled in Step 3). While empty the sites are **public**.
- `portalAllowedIpRanges` *(optional)* — CIDRs allowed to reach the portal (e.g. `["203.0.113.0/24"]`). Empty (default) = open to all networks. See [security.md](security.md#restricting-the-portal-by-ip-optional).
- `portalFrontDoorId` *(optional)* — the Front Door profile's ID when the portal is published through Front Door. Only that profile can then reach the portal. See [security.md](security.md#restricting-the-portal-to-front-door-optional).

---

## Step 2 — First deployment (infrastructure + code)

```powershell
az login
az account set --subscription <Subscription>

# Optional: preview the infrastructure changes
./deploy.ps1 -ResourceGroupName rg-idgov-dev -ParametersFile azResources/azuredeploy.parameters.dev.local.json -WhatIf

./deploy.ps1 -ResourceGroupName rg-idgov-dev -ParametersFile azResources/azuredeploy.parameters.dev.local.json
```

The script deploys `main.bicep`, zip-deploys the Function App, writes the portal's `config.json` (API URL and language) and zip-deploys the portal. It prints the portal and API URLs at the end.

---

## Step 3 — Create the Entra app registration (enables sign-in)

Authentication stays off until `authClientId` is set. One registration is shared by the portal (sign-in) and the API (token audience).

### Option A — Scripted (recommended)

`Setup/Configure-AuthAppRegistration.ps1` creates **or updates** the registration end to end — redirect URI, `api://<id>` scope + self pre-authorization, v2 access tokens (`requestedAccessTokenVersion = 2`, which the API's EasyAuth issuer expects), the `Governance.Admin` / `Governance.Member` app roles, and **Assignment required = Yes** on the enterprise app. Idempotent (safe to re-run against an existing app):

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All"
.\Setup\Configure-AuthAppRegistration.ps1 `
    -PortalHostname    "idgov-portal-dev.azurewebsites.net" `
    -CreateSecret -PortalAppName "idgov-portal-dev" -ResourceGroupName "rg-idgov-dev"
```

`-CreateSecret` mints the EasyAuth client secret and (with `-PortalAppName`/`-ResourceGroupName`) writes it to the portal as `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET`. Omit `-ApplicationId` to create a new app, or pass it to update an existing one.

Then: put the printed **Application (client) ID** into `authClientId` in the parameter file, **re-run `deploy.ps1`** (turns auth on), and `/.auth/logout` + sign in again. Finally assign users to the **Governance Admin** / **Governance Member** roles (Enterprise applications → Users and groups) — see [security.md](security.md#role-based-access-admin-vs-member).

### Option B — Manually

1. **App registrations → New registration** (single tenant). Note the **Application (client) ID**.
2. **Authentication → Add a platform → Web** — add the **portal** redirect URI and enable **ID tokens**:
   - `https://<portal-hostname>/.auth/login/aad/callback`
   - The API needs no redirect URI (it returns `401` instead of redirecting).
3. **Expose an API** — Application ID URI `api://<client-id>`, add scope `user_impersonation`, then **Authorized client applications → Add** the **same client ID** with that scope ticked. In **Manifest**, set `accessTokenAcceptedVersion` to `2`.
4. **App roles** — add `Governance.Admin` and `Governance.Member` (member type Users/Groups; the **Value** must be exactly those strings).
5. **Certificates & secrets → New client secret** — copy the value (**required**; see [security.md](security.md#the-easyauth-client-secret)) and store it on the **portal** app:
   ```powershell
   az webapp config appsettings set -g <rg> -n <portal-app> `
     --settings "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET=<secret-value>"
   ```
6. **Enterprise applications → this app → Properties → Assignment required = Yes**.
7. Set `"authClientId": { "value": "<client-id>" }` in the parameter file, **re-run `deploy.ps1`**, then `/.auth/logout` and sign in again. Confirm `access_token` at `/.auth/me`.

> **Assign roles:** Entra ID → **Enterprise applications** → this app → **Users and groups** → assign each user/group to **Governance Admin** or **Governance Member**. Only assigned users can sign in.

### Option C — Managed identity instead of a client secret

EasyAuth on the portal can redeem the sign-in code with a **user-assigned managed identity** (a federated identity credential on the app registration), so no client secret exists at all.

1. Set `"authUseManagedIdentity": { "value": true }` in the parameter file and run `deploy.ps1`. Bicep creates the identity `id-<appName>-portal-<env>` and the `OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID` setting on the portal.
2. Add the federated credential to the app registration:

   ```powershell
   $principalId = az identity show -g <RG> -n id-<App>-portal-<env> --query principalId -o tsv
   .\Setup\Configure-AuthAppRegistration.ps1 -PortalHostname "<portal-hostname>" `
       -ApplicationId "<client-id>" -ManagedIdentityPrincipalId $principalId -WhatIf
   ```

   Run it again without `-WhatIf` to apply. Optionally pass `-AdminGroupName` / `-MemberGroupName` to create two security groups and assign them to the app roles.
3. Remove any old client secrets from the app registration once sign-in works.

### Publishing the portal through Azure Front Door (optional)

When users reach the portal on a custom domain through Front Door:

| Parameter | Value |
|---|---|
| `portalPublicHostName` | The Front Door host, e.g. `identity.contoso.com`. Used for CORS and the links in mail. |
| `authForwardProxy` | `true`, so sign-in redirects go to the Front Door host instead of `azurewebsites.net`. |
| `portalFrontDoorId` | The profile's `frontDoorId`, so only your Front Door can reach the portal. |
| `apiAllowedIpRanges` | Optional. The API is called from the user's browser, not from Front Door, so restrict it to the users' egress ranges if you restrict it at all. |

Use the Front Door host as `-PortalHostname` for `Configure-AuthAppRegistration.ps1`, and point the Front Door origin at the portal's `azurewebsites.net` host. `/health/live` is excluded from sign-in and can be used as the health probe path.

---

## Step 4 — Grant RBAC + Graph permissions (Phase 2)

Run the `Setup/` scripts **in order** (with the Az PowerShell and Microsoft Graph modules). Do the RBAC step promptly — the Function App can't start without its storage roles.

```powershell
Connect-AzAccount
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All","RoleManagement.ReadWrite.Directory"

# 1. Azure RBAC (storage + App Insights) for the Function App identity             [Owner/UAA on RG]
.\Setup\Assign-AzureRbac.ps1 -ResourceGroupName "rg-idgov-dev" `
    -FunctionAppName "idgov-api-dev"

# 2. Microsoft Graph app roles                                        [Privileged Role Admin]
.\Setup\Configure-GraphPermissions.ps1 -ResourceGroupName "rg-idgov-dev" `
    -FunctionAppName "idgov-api-dev" `
    -WebAppName "idgov-portal-dev"

# 3. Entra directory roles                                            [Privileged Role Admin]
.\Setup\Assign-DirectoryRoles.ps1

# 4. Validate end to end
.\Setup\Validate-Deployment.ps1
```

The exact roles granted are listed in [security.md](security.md#managed-identity-permissions). Step 2 writes `Setup/_setup-context.json` (gitignored) that steps 3–4 read.

---

## Step 5 — First data load

The grid reads a cache populated by the timers (`SyncIdentityCache-Timer` every 30 min, `SyncPrivilegedUsers-Timer` daily). On a fresh deploy it's empty until the first run — trigger the timers from the Azure portal (Function App → the timer → **Code + Test → Test/Run**) or wait for the schedule.

**(Optional) Email notifications:** mail goes through Azure Communication Services (ACS) with the Function App's managed identity — no key or secret. Set `"acsEndpoint"` (e.g. `https://<acs-name>.<geo>.communication.azure.com`) and `"mailSenderAddress"` (a MailFrom address on a domain connected to that resource) in the parameter file, redeploy, then grant the identity a mail-sender role on the ACS resource with `Setup/Assign-CommunicationServicesRole.ps1` (Owner/UAA on the ACS resource). This enables both `SendExpiryNotifications-Timer` (daily) and `SendOwnerDigest-Timer` (1st of the month); both exit immediately while either value is empty.

Two related parameters are worth setting at the same time:

| Parameter | Default | What it does |
|---|---|---|
| `governanceEscalationTo` | *(empty)* | Mailbox(es) copied on post-expiry escalation, semicolon or comma separated. **Set this** — when an app's credential expires and every owner account is disabled, this is the only address left to tell. Empty means orphaned apps expire silently. Note this only reaches apps with notifications **enabled**; see below. |
| `secretMaxLifetimeDays` | `365` | Your maximum allowed client-secret lifetime. Secrets issued for longer get an advisory (not a risk flag). Also quoted in the renewal steps in the mail ("set the expiry to at most 12 months"). |
| `language` | `en` | Language of the portal **and** every notification mail: `en` (English) or `da` (Danish). One language per deployment. Risk reasons and advisories switch on the next sync run after a change. |

```json
"governanceEscalationTo": { "value": "identity-governance@contoso.com" },
"secretMaxLifetimeDays":  { "value": 365 },
"language":               { "value": "da" }
```

**On the renewal steps.** Expiry mail carries a short "How to renew — in this order" box beneath the button. Most owners have never rotated a client secret, and the sequence is what goes wrong: people create the new secret and delete the old one before the application is actually using the new value. The steps live in the mail rather than behind a link, because a link is a second click at exactly the moment someone is about to act — and they quote `secretMaxLifetimeDays`, so the recommended expiry in the mail and the advisory in the portal cannot drift apart.

> **The notification toggle gates every mail.** Warnings, post-expiry escalation, renewal confirmations *and* the monthly owner digest all require `NotifyOnExpiry` on the identity. An app with the toggle off is completely silent, escalation included. Before rolling out, use the portal's **Filter → Notifications off (eligible)** view to find apps that hold credentials and have an owner but no notifications, and switch them on.

---

## Verify

1. `https://<portal-hostname>` redirects to sign-in, then loads.
2. `https://<api-hostname>/api/health` returns `401` unauthenticated (expected once auth is on).
3. `Validate-Deployment.ps1` reports all checks passing. Once sign-in is on, it reports `config.json` as *protected by EasyAuth* instead of reading it.
4. After the first sync, the tabs show data.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Function App errors on first boot with a storage auth error | RBAC not granted yet — run `Assign-AzureRbac.ps1` (Step 4.1); allow a few minutes for role propagation, then restart. |
| Portal loads but API URL is undefined | `config.json` wasn't generated — re-run `deploy.ps1 -CodeOnly` and check that it printed the API URL. |
| Signed-in users get **401** | Check the `api://<client-id>` scope and that `authClientId` matches the parameter file. If you created the registration manually, set `accessTokenAcceptedVersion` to `2` in its manifest — the API only accepts v2 tokens. |
| Portal shows **"No access token"** | Missing client secret — set `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` (Step 3.4), `/.auth/logout`, sign in again. |
| App setting saved as `value: null` | `az` ran in a fresh shell / wrong subscription — re-capture the secret and `az account set --subscription <id>`. |
| Grid empty after deploy | Cache not populated — trigger the sync timers or wait for the schedule. |
| Sync timers log Graph **403** | Phase 2 incomplete or still propagating — re-run `Configure-GraphPermissions.ps1` / `Assign-DirectoryRoles.ps1`. |
| No telemetry / API hangs after enabling `disableAppInsightsLocalAuth` | The **Monitoring Metrics Publisher** grant isn't in place — run `Assign-AzureRbac.ps1` (Step 4.1) and let it propagate *before* setting `disableAppInsightsLocalAuth = true`. To recover a stalled app, remove the `APPLICATIONINSIGHTS_AUTHENTICATION_STRING` app setting and re-enable local auth on the component. |

---

## Redeploying

- **Code changes:** `./deploy.ps1 -ResourceGroupName <RG> -CodeOnly`. Phase 2 is not repeated.
- **Infra changes:** edit `main.bicep`, run `deploy.ps1 -WhatIf` to review, then re-run without it.
- **Adopting existing resources:** pin names in the parameter file (`storageAccountName`, `appPlanName`, `keyVaultName`) and read What-If carefully — a zip deploy **replaces all Function App content**, so any functions not in this repo will be removed.
