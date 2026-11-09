#!/usr/bin/env node
/*
 * Demo server for the Identity Governance Portal.
 *
 * Serves src/web-app and answers the portal's API calls with made-up demo data, so the
 * portal can be tried locally and screenshotted without an Azure deployment or a tenant.
 * Every name, ID and address below is fictitious. No dependencies: Node 18+ only.
 *
 *   node Tools/demo/mock-server.js            # http://localhost:8080
 *   PORT=9000 DEMO_LANG=da DEMO_ROLE=member node Tools/demo/mock-server.js
 *
 * DEMO_LANG: en (default) | da (portal UI only).  DEMO_ROLE: admin (default) | member.
 * Governance actions (tag, rename, owner change) return success but are not stored.
 */
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT) || 8080;
const LANG = process.env.DEMO_LANG === 'da' ? 'da' : 'en';
const ROLE = process.env.DEMO_ROLE === 'member' ? 'Governance.Member' : 'Governance.Admin';
const WEB_ROOT = path.resolve(__dirname, '..', '..', 'src', 'web-app');

// ── Deterministic helpers ──────────────────────────────────────────────────
let seed = 42;
function rnd() { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; }
function pick(a) { return a[Math.floor(rnd() * a.length)]; }
function guid(n) {
  // Fictitious, stable GUID derived from a counter.
  const h = (n * 2654435761 >>> 0).toString(16).padStart(8, '0');
  const t = (n * 40503 >>> 0).toString(16).padStart(12, '0').slice(-12);
  return `${h}-${h.slice(0, 4)}-4${h.slice(5, 8)}-a${h.slice(1, 4)}-${t}`;
}
const NOW = new Date();
function daysFromNow(d) { return new Date(NOW.getTime() + d * 86400000).toISOString(); }

// ── People (fictitious) ────────────────────────────────────────────────────
const people = [
  ['Alex Wilber', 'alex.wilber'], ['Megan Bowen', 'megan.bowen'], ['Adele Vance', 'adele.vance'],
  ['Lee Gu', 'lee.gu'], ['Nestor Wilke', 'nestor.wilke'], ['Pradeep Gupta', 'pradeep.gupta'],
  ['Isaiah Langer', 'isaiah.langer'], ['Lynne Robbins', 'lynne.robbins'], ['Grady Archie', 'grady.archie'],
  ['Joni Sherman', 'joni.sherman'], ['Miriam Graham', 'miriam.graham'], ['Johanna Lorenz', 'johanna.lorenz'],
].map(([n, u], i) => ({ DisplayName: n, UserPrincipalName: `${u}@contoso.com`, Enabled: i !== 8 && i !== 11 }));
const ME = people[0];

// ── Risk rules (a simplified mirror of Get-StaticRisk in SyncIdentityCache-Timer) ──
// Server-generated texts are English (the demo data does not follow DEMO_LANG; the portal UI does).
const T = {
  en: {
    noActiveOwner: 'No active owner - all owners are disabled accounts', noOwner: 'No owner', noOwnerAssigned: 'No owner assigned',
    ownerDisabled: 'Owner account disabled: {0}', minTwoOwners: 'Credential present - minimum two owners required (has {0})',
    expired: 'Expired credential', expiring: 'Credential expiring soon', privRole: 'Privileged directory role: {0}',
    highPerm: 'High-risk API permission', noSignIn: 'No sign-in in {0} days', ssoNoCa: 'SSO app with no Conditional Access policy',
    noCa: 'No Conditional Access policy', accountDisabledRoles: 'Account disabled but has roles', privNoSignIn: 'Privileged user, no sign-in in {0} days',
    fed: 'Federated credentials already configured - this client secret may be removable',
    considerFed: 'Renewing soon - consider workload identity federation instead of a new secret',
    lifetime: 'Secret issued for ~{0} months - standard is {1}',
    userVerified: 'User consent is limited to verified publishers. Consider disabling user consent entirely for tighter control.',
    emailOff: 'Email notifications for admin consent requests are disabled. Reviewers may miss incoming requests.',
  },
}.en;
function f(s, ...a) { return s.replace(/\{(\d)\}/g, (_, i) => a[i]); }
const HIGH_ROLES = ['Global Administrator', 'Privileged Role Administrator', 'Application Administrator', 'Cloud Application Administrator', 'User Administrator', 'Security Administrator'];

function risk(o) {
  const r = []; const live = o.Owners.filter(x => x.Enabled !== false); const dead = o.Owners.filter(x => x.Enabled === false);
  const ty = o.IdentityType; const fp = o.IsFirstParty;
  if (!live.length && ty === 'appregistration') r.push(o.Owners.length ? T.noActiveOwner : T.noOwner);
  if (!live.length && ty === 'enterpriseapp' && !fp) r.push(o.Owners.length ? T.noActiveOwner : T.noOwnerAssigned);
  if (live.length && dead.length && !fp) r.push(f(T.ownerDisabled, dead.map(x => x.DisplayName).join(', ')));
  if (o.Credentials.length && live.length < 2 && ty !== 'managedidentity' && !fp) r.push(f(T.minTwoOwners, live.length));
  const expired = o.Credentials.some(c => c.Status === 'Expired'); const expiring = o.Credentials.some(c => c.Status === 'Expiring');
  if (expired) r.push(T.expired); if (expiring) r.push(T.expiring);
  const hr = o.DirectoryRoles.filter(x => x.RiskLevel === 'High').map(x => x.RoleName);
  if (hr.length) r.push(f(T.privRole, hr.join(', ')));
  if (o.ApiPermissions.some(p => p.RiskLevel === 'High')) r.push(T.highPerm);
  const stale = ty === 'managedidentity' ? 90 : 180;
  if (ty !== 'appregistration' && o.DaysSinceSignIn >= stale) r.push(f(T.noSignIn, o.DaysSinceSignIn));
  let ssoNoCa = false;
  if (ty === 'enterpriseapp' && !fp && o.CAStatus === 'None') {
    if (o.SSOMode && o.SSOMode !== 'None') { r.push(T.ssoNoCa); ssoNoCa = true; } else r.push(T.noCa);
  }
  const high = (!live.length && ty === 'appregistration') || expired || hr.length > 0 || ssoNoCa;
  o.RiskReasons = r; o.RiskLevel = high ? 'High' : r.length ? 'Medium' : 'Healthy';
}

function cred(type, name, daysLeft, lifetime) {
  const status = daysLeft < 0 ? 'Expired' : daysLeft <= 30 ? 'Expiring' : 'Valid';
  return { Type: type, DisplayName: name, EndDateTime: daysFromNow(daysLeft), DaysLeft: daysLeft, Status: status, LifetimeDays: lifetime };
}
function base(type, name, i, extra) {
  const id = guid(i);
  return Object.assign({
    DisplayName: name, AppId: id, ObjectId: guid(i + 5000), CreatedOn: daysFromNow(-Math.floor(60 + rnd() * 1400)),
    Credentials: [], Owners: [], DirectoryRoles: [], ApiPermissions: [],
    MarkedForDeletion: false, MarkedBy: null, MarkedOn: null, ProposedName: null, RenameRequestedBy: null, RenameRequestedOn: null,
    NotifyOnExpiry: false, ContextPurpose: null, ContextSystem: null, ContextEnvironment: null, ContextCriticality: null,
    ContextUpdatedBy: null, ContextUpdatedOn: null, PendingOwnerChanges: [], IdentityType: type,
    LastSignInDate: null, DaysSinceSignIn: null, Advisories: [],
  }, extra);
}
function signIn(o, days) { if (days != null) { o.DaysSinceSignIn = days; o.LastSignInDate = daysFromNow(-days); } }

// ── App registrations ──────────────────────────────────────────────────────
const appNames = [
  'Contoso.Finance - Invoice Integration - PRD', 'Contoso.Finance - Invoice Integration - TST', 'Contoso.HR - Onboarding Portal - PRD',
  'Contoso.Sales - CRM Connector - PRD', 'Contoso.Platform - Image Builder - PRD', 'Contoso.Platform - Backup Automation',
  'Fabrikam.Payroll - Data Feed - PRD', 'Contoso.Web - Public Website - PRD', 'Contoso.Web - Public Website - DEV',
  'Contoso.Data - Reporting Warehouse - PRD', 'Contoso.Ops - Monitoring Webhook', 'Contoso.Ops - Ticket Sync - PRD',
  'Contoso.Legal - Contract Archive', 'Contoso.IT - Device Inventory', 'Contoso.IT - License Reporter',
  'Litware.Survey - Feedback Forms', 'Contoso.Mobile - Field App - PRD', 'Contoso.Platform - Deployment Agent - PRD',
  'Test app (temporary)', 'Contoso.Data - ML Scoring API - TST', 'Contoso.Marketing - Newsletter Sender',
  'Contoso.Facilities - Room Booking', 'Contoso.Security - Log Export', 'Northwind.Logistics - Order Bridge - PRD',
];
const graphPerms = [
  { Resource: 'Microsoft Graph', Permission: 'User.Read.All', RiskLevel: 'Medium' },
  { Resource: 'Microsoft Graph', Permission: 'Mail.Send', RiskLevel: 'Medium' },
  { Resource: 'Microsoft Graph', Permission: 'Directory.ReadWrite.All', RiskLevel: 'High' },
  { Resource: 'Microsoft Graph', Permission: 'Sites.Read.All', RiskLevel: 'Medium' },
  { Resource: 'Microsoft Graph', Permission: 'Application.ReadWrite.All', RiskLevel: 'High' },
  { Resource: 'Microsoft Graph', Permission: 'Group.Read.All', RiskLevel: 'Low' },
];
const appregs = appNames.map((n, i) => {
  const o = base('appregistration', n, i + 1);
  const nOwners = [2, 1, 2, 0, 3, 1, 2, 2, 1, 2][i % 10];
  for (let k = 0; k < nOwners; k++) o.Owners.push(people[(i * 3 + k * 5) % people.length]);
  if (i === 2) o.Owners.push(people[0]);
  const dl = [210, 12, 340, -9, 25, 400, 3, 95, -40, 180, 28, 300][i % 12];
  if (i % 5 !== 3) o.Credentials.push(cred(i % 4 === 0 ? 'Certificate' : 'Secret', i % 4 === 0 ? 'CN=' + n.split(' - ')[1] : 'client-secret', dl, i % 3 === 0 ? 730 : 365));
  if (i % 6 === 1) o.Credentials.push(cred('Secret', 'rotation-2', 300, 365));
  o.ApiPermissions = [graphPerms[i % graphPerms.length]].concat(i % 7 === 2 ? [graphPerms[2]] : []);
  o.NotifyOnExpiry = i % 3 !== 2;
  o.HasLinkedSP = true; o.HasFederation = i === 17 || i === 4;
  o.FederatedCredentials = o.HasFederation ? [{ Name: 'ci-deploy', Issuer: 'https://token.actions.githubusercontent.com', Subject: 'repo:contoso/platform:environment:prd' }] : [];
  if (o.HasFederation) o.Advisories.push(T.fed);
  if (o.Credentials.some(c => c.Type === 'Secret' && c.LifetimeDays > 365)) o.Advisories.push(f(T.lifetime, 24, 12));
  if (i === 1) { o.ContextPurpose = 'Sends approved invoices from the finance system to the payment provider.'; o.ContextSystem = 'Invoice platform'; o.ContextEnvironment = 'TST'; o.ContextCriticality = 'Important'; o.ContextUpdatedBy = 'megan.bowen@contoso.com'; o.ContextUpdatedOn = daysFromNow(-12); }
  if (i === 0) { o.ContextPurpose = 'Production invoice export.'; o.ContextSystem = 'Invoice platform'; o.ContextEnvironment = 'PRD'; o.ContextCriticality = 'Business critical'; o.ContextUpdatedBy = 'alex.wilber@contoso.com'; o.ContextUpdatedOn = daysFromNow(-30); }
  if (i === 18) { o.MarkedForDeletion = true; o.MarkedBy = 'adele.vance@contoso.com'; o.MarkedOn = daysFromNow(-2); }
  if (i === 13) { o.ProposedName = 'Contoso.IT - Device Inventory - PRD'; o.RenameRequestedBy = 'lee.gu@contoso.com'; o.RenameRequestedOn = daysFromNow(-4); }
  if (i === 3) o.PendingOwnerChanges = [{ Action: 'add', TargetName: 'Joni Sherman', TargetUpn: 'joni.sherman@contoso.com', RequestedBy: 'alex.wilber@contoso.com', RequestedOn: daysFromNow(-1) }];
  risk(o); return o;
});

// ── Enterprise apps ────────────────────────────────────────────────────────
const saas = [
  ['Contoso Expenses', 'SAML'], ['Fabrikam HR Cloud', 'SAML'], ['Litware Learning', 'OIDC'], ['Northwind Travel', 'Password'],
  ['Adatum Analytics', 'SAML'], ['Tailspin Ticketing', 'OIDC'], ['Wingtip Wiki', 'None'], ['Proseware Signatures', 'SAML'],
  ['Woodgrove Payroll', 'SAML'], ['Relecloud Video', 'OIDC'], ['Lucerne Surveys', 'None'], ['Coho Booking', 'Password'],
];
const microsoft = ['Microsoft Graph', 'Office 365 Exchange Online', 'Microsoft Teams Services', 'Azure Portal', 'Office 365 SharePoint Online'];
let n = 200;
const entapps = [];
saas.forEach(([name, sso], i) => {
  const o = base('enterpriseapp', name, n++, { AccountEnabled: true, IsFirstParty: false, HasLinkedAppReg: false, SSOMode: sso, CAPolicies: [], CAStatus: 'Covered' });
  const k = [1, 2, 0, 1, 2, 1, 0, 2, 1, 1, 0, 1][i];
  for (let j = 0; j < k; j++) o.Owners.push(people[(i * 2 + j * 7 + 1) % people.length]);
  if (i % 4 === 1 && sso !== 'None') { o.CAStatus = 'None'; } else { o.CAPolicies = ['Require MFA for all users']; }
  if (sso === 'None') o.CAStatus = 'None';
  if (sso === 'SAML') o.Credentials.push(cred('Certificate', 'CN=Microsoft Azure Federated SSO Certificate', [400, 18, 220, -3, 700, 90][i % 6], 1095));
  signIn(o, [2, 14, 1, 230, 7, 3, 400, 5, 1, 20, 190, 4][i]);
  o.NotifyOnExpiry = i % 2 === 0;
  risk(o); entapps.push(o);
});
// Enterprise apps behind the app registrations above.
appregs.slice(0, 8).forEach((a, i) => {
  const o = base('enterpriseapp', a.DisplayName, n++, { AppId: a.AppId, AccountEnabled: true, IsFirstParty: false, HasLinkedAppReg: true, SSOMode: 'OIDC (inferred)', CAPolicies: ['Require MFA for all users'], CAStatus: 'Covered' });
  o.Owners = a.Owners.slice(); signIn(o, [1, 3, 0, 260, 2, 9, 1, 6][i]); risk(o); entapps.push(o);
});
const firstParty = microsoft.map(name => {
  const o = base('enterpriseapp', name, n++, { AccountEnabled: true, IsFirstParty: true, HasLinkedAppReg: false, SSOMode: 'None', CAPolicies: [], CAStatus: 'Unknown' });
  signIn(o, 0); risk(o); return o;
});

// ── Managed identities ─────────────────────────────────────────────────────
const miNames = [
  ['func-orders-prd', 'System-assigned', 'Microsoft.Web/sites'], ['func-orders-tst', 'System-assigned', 'Microsoft.Web/sites'],
  ['id-backup-automation', 'User-assigned', 'Microsoft.ManagedIdentity/userAssignedIdentities'],
  ['app-website-prd', 'System-assigned', 'Microsoft.Web/sites'], ['vm-buildagent-01', 'System-assigned', 'Microsoft.Compute/virtualMachines'],
  ['id-reporting-etl', 'User-assigned', 'Microsoft.ManagedIdentity/userAssignedIdentities'], ['logic-invoice-approval', 'System-assigned', 'Microsoft.Logic/workflows'],
  ['aks-platform-agentpool', 'User-assigned', 'Microsoft.ManagedIdentity/userAssignedIdentities'], ['adf-datawarehouse', 'System-assigned', 'Microsoft.DataFactory/factories'],
  ['id-legacy-sync', 'User-assigned', 'Microsoft.ManagedIdentity/userAssignedIdentities'],
];
const mis = miNames.map(([name, kind, rt], i) => {
  const rg = ['rg-orders-prd', 'rg-orders-tst', 'rg-platform-prd', 'rg-web-prd', 'rg-build', 'rg-data-prd', 'rg-finance-prd', 'rg-platform-prd', 'rg-data-prd', 'rg-legacy'][i];
  const o = base('managedidentity', name, 400 + i, {
    AccountEnabled: true, ManagedIdentityType: kind,
    AzureResourceId: `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/${rg}/providers/${rt}/${name}`,
  });
  if (i === 2 || i === 9) o.ApiPermissions = [graphPerms[i === 9 ? 2 : 3]];
  if (i === 7) o.DirectoryRoles = [{ RoleName: 'Directory Readers', RiskLevel: 'Medium' }];
  signIn(o, [0, 4, 1, 0, 35, 2, 1, 0, 3, 210][i]);
  risk(o); return o;
});

// ── Privileged users ───────────────────────────────────────────────────────
const privDefs = [
  [0, ['Global Administrator'], 1, 'IT Manager', 'IT'], [1, ['Application Administrator'], 3, 'Cloud Engineer', 'IT'],
  [2, ['Security Administrator', 'Security Reader'], 0, 'Security Analyst', 'Security'], [3, ['User Administrator'], 12, 'Service Desk Lead', 'IT'],
  [8, ['Cloud Application Administrator'], 140, 'Former Contractor', 'IT'], [5, ['Global Administrator'], null, 'Break-glass account', 'IT'],
  [9, ['Reports Reader'], 20, 'Controller', 'Finance'], [10, ['Exchange Recipient Administrator'], 5, 'Messaging Engineer', 'IT'],
];
const privs = privDefs.map(([pi, roles, days, title, dept], i) => {
  const p = people[pi];
  const o = base('privilegeduser', p.DisplayName, 600 + i, {
    UserPrincipalName: pi === 5 ? 'breakglass01@contoso.onmicrosoft.com' : p.UserPrincipalName, AccountEnabled: p.Enabled,
    JobTitle: title, Department: dept, RoleCount: roles.length,
    DirectoryRoles: roles.map(r => ({ RoleName: r, RiskLevel: HIGH_ROLES.includes(r) ? 'High' : 'Medium' })),
  });
  if (pi === 5) o.DisplayName = 'Break-glass 01';
  o.AppId = o.ObjectId; signIn(o, days);
  const r = []; const hr = o.DirectoryRoles.filter(x => x.RiskLevel === 'High').map(x => x.RoleName);
  if (hr.length) r.push(f(T.privRole, hr.join(', ')));
  if (!o.AccountEnabled) r.push(T.accountDisabledRoles);
  if (days != null && days >= 60) r.push(f(T.privNoSignIn, days));
  o.RiskReasons = r; o.RiskLevel = hr.length || !o.AccountEnabled || (days >= 60) ? 'High' : r.length ? 'Medium' : 'Healthy';
  return o;
});

// ── Dashboard summary (mirrors section 9 of SyncIdentityCache-Timer) ───────
function summary() {
  const ea = entapps; const all = [...appregs, ...ea, ...mis, ...privs];
  const own = [...appregs, ...ea]; const po = own.filter(o => o.Owners.length).length / own.length * 100;
  const cs = own.filter(o => o.Credentials.length); const pc = cs.filter(o => !o.Credentials.some(c => c.Status !== 'Valid')).length / cs.length * 100;
  const cas = ea.filter(o => o.SSOMode && o.SSOMode !== 'None' && o.CAStatus !== 'Unknown'); const pca = cas.filter(o => o.CAStatus === 'Covered').length / cas.length * 100;
  const ss = [...ea, ...mis].filter(o => o.LastSignInDate);
  const pst = ss.filter(o => o.DaysSinceSignIn < (o.IdentityType === 'managedidentity' ? 90 : 180)).length / ss.length * 100;
  const r2 = x => Math.round(x * 100) / 100;
  return {
    Total: all.length, OwnershipPct: r2(po), CredPct: r2(pc), CaPct: r2(pca), StalePct: r2(pst),
    HealthScore: r2(po * 0.3 + pc * 0.3 + pca * 0.2 + pst * 0.2),
    ExpiringCount: all.filter(o => o.Credentials.some(c => c.Status !== 'Valid')).length,
    PrivilegedCount: all.filter(o => o.DirectoryRoles.length || o.ApiPermissions.some(p => p.RiskLevel === 'High')).length,
    LastSynced: daysFromNow(-0.01),
  };
}
const tenantConfig = {
  UserConsentSetting: 'VerifiedPublishersOnly', AdminConsentEnabled: true, ReviewersConfigured: true, EmailNotificationsEnabled: false,
  OverallStatus: 'Warning', LastSynced: daysFromNow(-0.2),
  Findings: [{ Severity: 'Warning', Setting: 'UserConsent', Message: T.userVerified }, { Severity: 'Warning', Setting: 'EmailNotifications', Message: T.emailOff }],
  Dashboard: summary(),
};

// ── API ────────────────────────────────────────────────────────────────────
function ownedByMe(o) { return o.Owners.some(x => x.UserPrincipalName === ME.UserPrincipalName); }
function identities(q) {
  const type = q.get('type');
  let list = { appregistration: appregs, managedidentity: mis, privilegeduser: privs }[type];
  if (type === 'enterpriseapp') {
    const fp = q.get('firstParty');
    list = fp === 'only' ? firstParty : fp === 'exclude' ? entapps : entapps.concat(firstParty);
  }
  if (!list) return null;
  if (ROLE === 'Governance.Member') list = (type === 'appregistration' || type === 'enterpriseapp') ? list.filter(ownedByMe) : [];
  return list;
}
function api(req, url, res) {
  const route = url.pathname.replace(/^\/api\//, '');
  const send = (code, body) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };
  switch (route) {
    case 'GetIdentities': { const l = identities(url.searchParams); return l ? send(200, l) : send(400, { error: 'unknown type' }); }
    case 'GetTenantConfig': return send(200, ROLE === 'Governance.Admin' ? tenantConfig : { OverallStatus: 'Unknown', Findings: [], Dashboard: null });
    case 'GetNotifyConfig': return send(200, { available: true });
    case 'GetOwnerRequests': return send(200, []);
    case 'SearchUsers': {
      const s = (url.searchParams.get('q') || url.searchParams.get('search') || '').toLowerCase();
      return send(200, people.filter(p => p.Enabled && (p.DisplayName + p.UserPrincipalName).toLowerCase().includes(s))
        .map((p, i) => ({ Id: guid(900 + i), DisplayName: p.DisplayName, UserPrincipalName: p.UserPrincipalName, JobTitle: null })));
    }
    case 'TagApplication': case 'RequestOwnerChange': return send(200, { success: true, demo: true });
    case 'health': return send(200, { status: 'ok' });
    default: return send(404, { error: 'not found' });
  }
}

// ── Static files + EasyAuth stand-ins ──────────────────────────────────────
// Opens a view once the data has loaded. Demo-only: injected by this server, not part of the portal.
const DEEP_LINK = `<script>(function(){var q=new URLSearchParams(location.search);
function go(){if(typeof allLoaded!=='function'||!allLoaded())return setTimeout(go,200);
if(q.get('view')==='list')switchTab(q.get('type')||'appregistration');else showView(q.get('view'));
if(q.get('details'))openDetails(q.get('details'));}setTimeout(go,300);})();</script>`;
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon' };
http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  if (url.pathname.startsWith('/api/')) return api(req, url, res);
  if (url.pathname === '/config.json') { res.writeHead(200, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify({ apiBaseUrl: '/api', language: LANG })); }
  if (url.pathname === '/.auth/me') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify([{ access_token: 'demo-token', user_id: ME.UserPrincipalName, user_claims: [
      { typ: 'name', val: ME.DisplayName }, { typ: 'preferred_username', val: ME.UserPrincipalName }, { typ: 'roles', val: ROLE }] }]));
  }
  if (url.pathname === '/.auth/logout') { res.writeHead(302, { Location: '/' }); return res.end(); }
  const rel = decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname);
  const file = path.join(WEB_ROOT, rel);
  if (!file.startsWith(WEB_ROOT)) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); return res.end('Not found'); }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream' });
    // Deep links for screenshots: /?view=list&type=enterpriseapp&details=<appId>
    if (rel === '/index.html' && url.searchParams.has('view')) data = Buffer.from(String(data).replace('</body>', DEEP_LINK + '</body>'));
    res.end(data);
  });
}).listen(PORT, () => console.log(`Demo portal on http://localhost:${PORT} (language ${LANG}, role ${ROLE})`));
