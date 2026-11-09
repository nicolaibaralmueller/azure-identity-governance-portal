# Tools — Governance Apply Scripts

These scripts are run by an administrator to **enforce governance actions** that users have recorded in the portal. The portal itself never modifies Entra ID — it only writes intent to Azure Table Storage. An admin runs one of these scripts to actually apply the changes.

## How changes are applied

The portal operates in two phases:

1. **Record** — a portal user marks an identity for deletion, requests a rename, or requests an owner change. The action is written to Azure Table Storage and shown in the portal with a pending badge. Nothing in Entra ID changes at this point.

2. **Apply** — an admin runs the appropriate script below using their own Azure credentials. The script reads the pending actions from storage, presents them for confirmation, and executes the changes in Entra ID.

This split keeps the Function App's managed identity read-only (no write permissions to Entra ID) and ensures a human admin reviews and approves each batch before it takes effect.

---

## Scripts

### `Apply-PendingDeletions.ps1`

Reads all identities marked for deletion in `GovernanceState` and removes them from Entra ID.

```powershell
.\Apply-PendingDeletions.ps1
```

- Presents marked items in a grid — select the ones to delete, then close the grid
- Calls `Remove-AzADApplication` / `Remove-AzADServicePrincipal` for each selected item
- Clears the `MarkedForDeletion` flag on success
- The sync timer (runs every 30 min) will drop deleted items from the cache automatically

---

### `Apply-PendingRenames.ps1`

Reads all identities with a `ProposedName` in `GovernanceState` and renames them in Entra ID.

```powershell
.\Apply-PendingRenames.ps1
```

- Updates `displayName` via `Update-AzADApplication` / `Update-AzADServicePrincipal`
- Handles linked app registrations and enterprise apps (renames both if applicable)
- Clears `ProposedName` on success

---

### `Apply-PendingOwnerChanges.ps1`

Reads all pending owner add/remove requests from `AppOwnerRequests` and applies them via the Graph API.

```powershell
.\Apply-PendingOwnerChanges.ps1
```

- Uses `Invoke-AzRestMethod` to call the Graph `owners/$ref` endpoint
- Sets `Status = 'completed'` on each request after successful apply

---

### `New-TestExpiryApp.ps1`

Test helper, not an apply script. Creates a throwaway app registration with one client secret per notification threshold (30/14/7/1 days by default) and an owner, so the expiry mail can be tested without waiting for a real credential to age.

```powershell
.\New-TestExpiryApp.ps1
```

- The owner defaults to the signed-in user (override with `-OwnerUpn`)
- No mail is sent unless notifications are on for the app: switch the toggle on in the portal, or pass `-EnableNotifications -StorageAccountName <sa> -ResourceGroupName <rg>`
- Afterwards, trigger `SyncIdentityCache-Timer` and then `SendExpiryNotifications-Timer` for an immediate send instead of waiting for 08:00 UTC
- Delete the test app when done

---

## Run order

There is no required order between the three scripts — they operate on independent tables and independent Entra ID object types. Run whichever is relevant to the pending actions shown in the portal banner.

After running any script, wait up to 30 minutes for the next `SyncIdentityCache-Timer` execution to pick up the changes and clear the pending badges from the portal.

### Triggering an immediate cache refresh

To see the result in the portal straight away, trigger the sync timer manually:

1. Azure portal → **Function Apps** → select the governance Function App.
2. Under **Functions**, select **SyncIdentityCache-Timer**.
3. Select **Code + Test** → **Test/Run** → leave the body empty → **Run**.

The function re-syncs all app registrations, enterprise apps, and managed identities from Entra ID and overwrites `IdentityCache`. Reload the portal to see the updated names and cleared pending badges.

### Manually editing GovernanceState

If a pending badge is stuck (e.g. the apply script succeeded but the flag was not cleared), you can clear it directly in Table Storage:

1. Azure portal → **Storage accounts** → select the governance storage account.
2. Under **Data storage**, select **Tables** → **GovernanceState**.
3. Filter by **RowKey** = the App ID (GUID).
4. Open the entity and clear the relevant fields:
   - Rename stuck: clear `ProposedName`, `RenameRequestedBy`, `RenameRequestedOn`.
   - Deletion mark stuck: set `MarkedForDeletion` to `false`, clear `MarkedBy`, `MarkedOn`.
5. Select **Update** to save.

The portal reflects the change on the next data load (no cache sync needed — governance state is read live from `GovernanceState`, not from `IdentityCache`).

---

## Development helpers

### `demo/mock-server.js` and `demo/take-screenshots.js`

Run the portal locally against a demo API with made-up data (Node 18+, no dependencies):

```bash
node Tools/demo/mock-server.js                                 # http://localhost:8080
DEMO_ROLE=member DEMO_LANG=da node Tools/demo/mock-server.js   # member view, Danish UI
```

Governance actions return success but are not stored. `take-screenshots.js` starts the server, captures every page with headless Chrome or Edge into `docs/screenshots/`, and stops it again.

### `New-Favicon.ps1`

Regenerates `src/web-app/favicon.ico` (16/32/48 px) and `apple-touch-icon.png` (180 px) from the shield-and-check mark in `src/web-app/favicon.svg`. Modern browsers use the SVG directly; the generated files are fallbacks. Run it after changing the SVG (Windows, PowerShell 7):

```powershell
.\New-Favicon.ps1
```
