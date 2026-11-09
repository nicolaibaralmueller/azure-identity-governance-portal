# Contributing

Thanks for your interest in improving the Identity Governance Portal. This is a
self-hosted Azure solution (Bicep + PowerShell Function App + a static portal),
so most contributions are bug fixes, doc improvements, or small features.

## Before you start

- For anything non-trivial, **open an issue first** to agree on the approach.
- For security issues, see [SECURITY.md](SECURITY.md) — report them privately.

## Keep tenant data in its place

- Environment-specific values (subscription IDs, resource names, client IDs, IP
  ranges) belong **only** in your own git-ignored
  `azResources/azuredeploy.parameters.<env>.local.json`. The committed parameter
  files, code, scripts, and docs use placeholders or `Contoso` examples.
- **Never commit secrets** — not in parameter files, not in scripts. Secrets live in
  App Service settings or Key Vault (see [docs/security.md](docs/security.md)).
- `Setup/_setup-context.json` is generated locally and git-ignored; keep it that way.
- Screenshots come from the demo server only — never from a real tenant.

## Development

- **Infrastructure:** `azResources/main.bicep` (+ `azuredeploy.parameters.*.json`).
  Validate with `az bicep build -f azResources/main.bicep`.
- **API:** PowerShell 7.6 Functions under `src/function-app/`. HTTP triggers are
  `authLevel: anonymous` (EasyAuth fronts auth); timer triggers populate the cache.
- **Portal:** static files under `src/web-app/` (vanilla JS, no build step). Colours
  live only in `css/themes/*.css`; components use the theme tokens. See
  [docs/architecture.md](docs/architecture.md#portal) for the file layout and how to add a theme.
- **Try UI changes locally:** `node Tools/demo/mock-server.js` serves the portal
  against made-up demo data. Regenerate screenshots with `node Tools/demo/take-screenshots.js`.
- **Deploy to test your change:** run `deploy.ps1` (or `deploy.ps1 -CodeOnly`)
  against your own dev environment. See [docs/setup-guide.md](docs/setup-guide.md).
- **Check before a PR:** `az bicep build -f azResources/main.bicep`, and
  `Invoke-ScriptAnalyzer -Path . -Recurse` for the PowerShell.

## Style

- Match the surrounding code — naming, formatting, and comment density.
- Keep PowerShell scripts **idempotent** and report failures clearly (don't mark
  success on error).
- Keep changes focused; avoid unrelated reformatting in the same PR.

## Pull requests

1. Fork the repository and branch from `main`.
2. Make the change; verify it deploys/validates where applicable.
3. Confirm `git diff` contains **no** secrets or stray tenant values.
4. Open a PR describing the change and how you tested it.
