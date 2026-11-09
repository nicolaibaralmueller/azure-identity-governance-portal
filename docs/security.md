# Security model

The trust, identity, and secret model behind the portal. For deployment steps see [setup-guide.md](setup-guide.md); for components see [architecture.md](architecture.md).

## Two identities, two directions

- **Outbound (app → Graph/Storage):** both the Function App and Web App use **system-assigned managed identities**. No secrets are involved in reading Microsoft Graph or Storage data.
- **Inbound (user → app):** handled by **App Service Authentication (EasyAuth)** against a single Entra **app registration**. This is the one place a hand-managed secret can exist, and it can be avoided with a managed identity (below).

## User sign-in (EasyAuth)

EasyAuth is codified in `main.bicep` and turns on automatically once `authClientId` is supplied:

- **API** — `requireAuthentication: true`, `unauthenticatedClientAction: Return401`. The platform rejects every unauthenticated request with HTTP 401 *before any function code runs*. Only tokens issued to the app registration (`allowedApplications` / `allowedAudiences` pinned to `authClientId`) are accepted. Because EasyAuth fronts the app, the `X-MS-CLIENT-PRINCIPAL-NAME` header the API trusts cannot be spoofed. Timer triggers don't traverse HTTP auth and keep running.
- **Portal** — anonymous users are redirected to sign in; the access token is held in the token store so the SPA can call the API via `/.auth/me`.

Until `authClientId` is set, **both sites are publicly accessible** — the deploy succeeds but the API accepts anonymous calls. Set it and re-run `deploy.ps1` to lock down.

### Restricting who can sign in

By default any tenant user can sign in. To restrict: Entra ID → **Enterprise applications** → this app → **Properties** → **Assignment required = Yes**, then **Users and groups** → assign the allowed users or group (group assignment requires Entra ID P1).

## The EasyAuth client secret

The single hand-managed credential, unless you use the managed-identity option below. App Service Authentication needs a client credential to redeem the sign-in code for an **access token**; without it, sign-in yields only an ID token and `/.auth/me` has no `access_token` (the portal shows *"No access token"*). It lives as the `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` app setting on the **portal** Web App (referenced by Bicep via `clientSecretSettingName`, kept out of source control). It can be moved to a Key Vault reference if preferred.

**Secretless option.** With `authUseManagedIdentity = true`, Bicep creates a user-assigned identity for the portal and EasyAuth redeems the code with a federated identity credential on the app registration instead of a secret (`OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID`). `Configure-AuthAppRegistration.ps1 -ManagedIdentityPrincipalId` adds the credential. Assign that identity to no other resource, or that resource can act as the app registration. Steps: [setup-guide.md](setup-guide.md#option-c--managed-identity-instead-of-a-client-secret).

Storage is otherwise **fully identity-based** — no account keys for the data plane. (`AzureWebJobsStorage` uses the identity-based `__accountName` form on the dedicated plan; the older Azure Files connection string required by Consumption is not used here.)

## Managed-identity permissions

Granted to the Function App identity by the `Setup/` scripts (the deploying principal only needs Contributor, which cannot create role assignments).

**Azure RBAC** (`Assign-AzureRbac.ps1`):

| Role | Scope | Why |
|---|---|---|
| Storage Blob Data Owner | Storage account | Identity-based `AzureWebJobsStorage` host storage |
| Storage Table Data Contributor | Storage account | Read/write the portal tables |
| Monitoring Metrics Publisher | Application Insights | Entra-authenticated telemetry ingestion (once `disableAppInsightsLocalAuth` is on) |

**Azure Communication Services** (`Assign-CommunicationServicesRole.ps1`, only when mail is on): an existing role you name with `-RoleName` on your Communication Services resource, so the identity can send mail without a key. The resource, its email domain and the role are prerequisites you create yourself; nothing in this repository builds them. Recommended: a custom role with only `Microsoft.Communication/CommunicationServices/Read`, `Microsoft.Communication/CommunicationServices/Write` and `Microsoft.Communication/EmailServices/write` (see [setup-guide.md](setup-guide.md#email-notifications-optional)).

**Microsoft Graph application roles** (`Configure-GraphPermissions.ps1`):

| Permission | Why |
|---|---|
| `Application.Read.All` | App registrations + enterprise apps (and their owners) |
| `Directory.Read.All` | Directory objects |
| `User.Read.All` / `GroupMember.Read.All` | Owner / user details |
| `Policy.Read.All` | Conditional Access coverage + consent settings |
| `AuditLog.Read.All` | Service-principal sign-in activity (staleness) |

**Entra directory roles** (`Assign-DirectoryRoles.ps1`): **Directory Readers**. The script's role list can be extended, but the solution needs no write role.

All are **read** permissions except where governance writes are performed by an admin (owner changes, etc.); the portal does not grant the managed identity write access to identities it cannot already manage.

## Transport security

Both sites require **TLS 1.3** as the minimum inbound version (`minTlsVersion` / `scmMinTlsVersion` on the portal and the API). This forbids the legacy 1.2 cipher suites (CBC, non-PFS key exchange) and is the version most scanners and Defender for Cloud now expect. It governs only **inbound** connections to the sites — outbound calls (Graph, Storage, the managed-identity token endpoint) are unaffected. Modern browsers all negotiate 1.3; the only compatibility risk is an older TLS-inspection proxy in front of the portal, so confirm none is in the access path before tightening further. The storage account stays at `TLS1_2` because Azure Storage does not yet accept 1.3 as a minimum.

## Telemetry ingestion (Application Insights)

App Insights can be hardened to reject **local (instrumentation-key) auth** so that only Entra-authenticated principals write telemetry — the Function App then ingests with its **managed identity** (`APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`), holding **Monitoring Metrics Publisher** on the component. This removes the instrumentation key as a usable bearer credential and stops anyone who obtains it from **spoofing log/audit telemetry** or flooding ingestion to run up cost.

This is **opt-in and off by default**, controlled by the `disableAppInsightsLocalAuth` parameter, because of a hard ordering dependency: **enabling it before the role is granted makes the Function host stall on rejected telemetry** (the API hangs and the portal loads no data). The safe sequence is:

1. Deploy with `disableAppInsightsLocalAuth = false` (default) — telemetry uses the key, app runs.
2. Run `Assign-AzureRbac.ps1` to grant **Monitoring Metrics Publisher**, and let it propagate (a few minutes).
3. Set `disableAppInsightsLocalAuth = true` in the parameter file and redeploy. Bicep then disables local auth *and* adds the `Authorization=AAD` setting together.

The role grant is still part of `Assign-AzureRbac.ps1` regardless, so the identity is ready before you flip the switch.

## Network posture

The portal is a static page whose API calls originate from **each user's browser**, so the API cannot be restricted to a fixed server IP or VNet — there is no single server-side caller to allow-list. It can be limited to the users' own egress ranges with `apiAllowedIpRanges`. **Identity-based authentication is the correct lock-down for the API.** Going network-private would require a higher App Service tier plus a server-side proxy in the web app to originate the API calls.

### Restricting the portal to Front Door (optional)

When the portal is published through Azure Front Door, set `portalFrontDoorId` to the profile's `frontDoorId` (a GUID; `az afd profile show --query frontDoorId`):

```json
"portalFrontDoorId": { "value": "00000000-0000-0000-0000-000000000000" }
```

This adds an `Allow` rule for the `AzureFrontDoor.Backend` service tag that also requires the `X-Azure-FDID` header to match, so only **your** Front Door profile gets through, not any other Front Door customer. Network filtering by source IP (e.g. the office) then belongs in the Front Door WAF policy.

### Restricting the portal by IP (optional)

The **portal** (web app) *can* also be limited to a known set of source networks — useful when access should come only from a corporate range or VPN and there is no Front Door. Set the `portalAllowedIpRanges` parameter in `main.bicep` to a list of CIDRs:

```json
"portalAllowedIpRanges": { "value": ["203.0.113.10/32", "198.51.100.0/24"] }
```

When either parameter is set, the rules become `Allow` access-restriction rules on the portal and the default action is **Deny** for everything else. When both are empty (the default), the portal is open to all networks. The **SCM/Kudu** endpoint has its own rules (`scmAllowedServiceTags`, `scmAllowedIpRanges`) so deployments can still reach it. Note this filters *network* access to the portal page; the API remains protected by EasyAuth regardless (browsers from an allowed range still present a valid token).

## Role-based access (admin vs member)

Two **App Roles** on the app registration control what a signed-in user sees:

| Role | Sees |
|---|---|
| `Governance.Admin` | Everything — all four identity types, the dashboard, consent posture, and all governance actions |
| `Governance.Member` | Only the **App Registrations and Enterprise Apps they own**. No Managed Identities / Privileged Users tabs, no dashboard/consent. On their own apps they may switch **expiry notifications** on/off, **describe** the app, **request a rename**, and **flag it for decommissioning** — every one of which only *records intent*; nothing reaches Entra ID until an admin runs the apply scripts. Adding or removing **owners stays admin-only**, because that is a privilege change |

**Enforcement is server-side.** `Get-Caller` (in `profile.ps1`) reads the role from the EasyAuth-injected `X-MS-CLIENT-PRINCIPAL` header, and the endpoints act on it:
- `GetIdentities` filters to the member's owned apps (case-insensitive UPN match) and returns **403** to members for managed-identity / privileged-user types.
- `RequestOwnerChange`, `SearchUsers` and `GetOwnerRequests` return **403** to members.
- `TagApplication` accepts `notify` / `unnotify` / `rename` / `mark` / `unmark` / `context` from a member **only after re-checking ownership against the cache** (`Test-CallerOwnsIdentity`) — posting another app's appId directly returns **403**. Any other action requires `Governance.Admin`.
- `GetTenantConfig` withholds the consent posture and dashboard summary from members.

**Why member self-service is safe.** The Function App's managed identity holds no write permission on Entra ID. Every governance action — a member's or an admin's — writes a row to Table Storage and stops there; an administrator applies it later with their own credentials via `Tools/Apply-*.ps1`. Widening what a member may *request* therefore widens no privilege, only the queue an admin reviews.

The portal hides the corresponding tabs, dashboard, and buttons — but that is **cosmetic**; the control is the API. Two edge cases by design: a caller with **no recognised role is denied** (defense in depth behind *Assignment required*); and if EasyAuth is **not configured at all** (public mode) there is no role, so the API grants full access and the no-auth deployment still works.

### Setup

`Setup/Configure-AuthAppRegistration.ps1` performs steps 1–2 automatically (see [setup-guide.md](setup-guide.md#step-3--create-the-entra-app-registration-enables-sign-in)); step 3 is done in the portal.

1. App registration → **App roles** → create two roles (allowed member type **Users/Groups**) with values `Governance.Admin` and `Governance.Member`.
2. Enterprise application → **Properties → Assignment required = Yes** — **required**, not optional: it blocks unassigned users at sign-in.
3. **Users and groups** → assign each user (or group) to one of the two roles. The role flows into the token automatically; confirm it appears at `/.auth/me` (app roles only show for **assigned** users).
