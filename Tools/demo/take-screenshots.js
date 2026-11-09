#!/usr/bin/env node
/*
 * Regenerates docs/screenshots/*.png from the demo server with headless Chrome (or Edge).
 *
 *   node Tools/demo/take-screenshots.js
 *   CHROME="/path/to/chrome" node Tools/demo/take-screenshots.js
 *
 * Starts mock-server.js on a free port, captures each page, then stops the server.
 */
'use strict';
const { spawn, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const OUT = path.join(ROOT, 'docs', 'screenshots');
const PORT = 8790;
const BASE = `http://localhost:${PORT}`;

const CANDIDATES = [
  process.env.CHROME,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
].filter(Boolean);
const CHROME = CANDIDATES.find(p => fs.existsSync(p));
if (!CHROME) { console.error('Chrome/Edge not found. Set CHROME to its path.'); process.exit(1); }

function shot(file, url, opts = {}) {
  const args = [
    '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check',
    `--user-data-dir=${path.join(require('os').tmpdir(), 'igp-shots-' + process.pid + '-' + file)}`,
    `--window-size=${opts.size || '1440,900'}`, '--virtual-time-budget=8000',
    `--screenshot=${path.join(OUT, file)}`,
  ];
  if (opts.dark) args.push('--force-dark-mode', '--blink-settings=preferredColorScheme=0');
  args.push(url);
  execFileSync(CHROME, args, { stdio: 'ignore', timeout: 60000 });
  console.log('wrote docs/screenshots/' + file);
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const server = spawn(process.execPath, [path.join(__dirname, 'mock-server.js')], { env: Object.assign({}, process.env, { PORT: String(PORT) }), stdio: 'ignore' });
  try {
    await new Promise(r => setTimeout(r, 800));
    const apps = await (await fetch(`${BASE}/api/GetIdentities?type=appregistration`)).json();
    const detail = (apps.find(a => a.ContextPurpose && a.RiskLevel !== 'Healthy') || apps[0]).AppId;
    shot('overview.png', `${BASE}/?view=overview`, { size: '1440,1100' });
    shot('app-registrations.png', `${BASE}/?view=list&type=appregistration`);
    shot('enterprise-apps.png', `${BASE}/?view=list&type=enterpriseapp`);
    shot('managed-identities.png', `${BASE}/?view=list&type=managedidentity`);
    shot('privileged-users.png', `${BASE}/?view=list&type=privilegeduser`);
    shot('details-pane.png', `${BASE}/?view=list&type=appregistration&details=${detail}`);
    shot('pending-actions.png', `${BASE}/?view=pending`);
    shot('consent-settings.png', `${BASE}/?view=consent`);
    shot('dark-theme.png', `${BASE}/?view=overview`, { dark: true });
  } finally {
    server.kill();
  }
}
main().catch(e => { console.error(e); process.exit(1); });
