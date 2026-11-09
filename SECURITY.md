# Security Policy

## Supported versions

Security fixes are applied to the latest version of the `main` branch. Older
versions are not maintained.

## Reporting a vulnerability

**Please do not report security vulnerabilities in a public issue, PR, or other
shared channel.**

Report them privately through GitHub's **Report a vulnerability** button on the
repository's **Security** tab, or contact the maintainer at `33453919+nicolaibaralmueller@users.noreply.github.com`.

Please include:

- A description of the issue and its impact.
- Steps to reproduce (or a proof of concept).
- The affected file(s)/component (portal, Function App API, Bicep, setup scripts).

We aim to acknowledge reports within **5 business days** and to agree on a
fix and disclosure timeline once the issue is confirmed.

## Scope and shared responsibility

This solution deploys into **your own** Azure subscription and Entra ID tenant.
Some of the security posture is determined by how you deploy and configure it,
not by this codebase. In particular, deployers are responsible for:

- Granting the Function App managed identity **least-privilege** Graph/RBAC roles
  (see [docs/security.md](docs/security.md)) and reviewing them periodically.
- Protecting the EasyAuth **client secret** (`MICROSOFT_PROVIDER_AUTHENTICATION_SECRET`)
  and any Key Vault secrets.
- Restricting portal access (`portalAllowedIpRanges`, role assignments) as appropriate.
- Keeping secrets out of parameter files and `Setup/_setup-context.json` out of
  source control (it is git-ignored by default).

Issues that stem solely from a misconfiguration of *your* deployment (rather than a
flaw in this code) are best raised as a normal issue.
