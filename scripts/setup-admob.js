#!/usr/bin/env node
/**
 * setup-admob.js
 *
 * One-time script to:
 *   1. Authorize with Google via OAuth2 (opens browser)
 *   2. Create (or find) the imghost app record in AdMob
 *   3. Create (or find) banner + interstitial ad units
 *   4. Patch AdManager.swift with the real ad unit IDs
 *   5. Patch Info.plist with GADApplicationIdentifier + NSUserTrackingUsageDescription
 *
 * Prerequisites:
 *   - Node.js 18+
 *   - npm install google-auth-library open   (run once in this directory)
 *   - OAuth2 Desktop credentials JSON downloaded from Google Cloud Console
 *
 * Usage:
 *   node scripts/setup-admob.js path/to/credentials.json
 *
 * On subsequent runs the cached token in .admob-tokens.json is reused
 * so the browser step is skipped.
 */

import { createServer } from 'node:http';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

// ─── Paths ────────────────────────────────────────────────────────────────────

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const AD_MANAGER_PATH = resolve(ROOT, 'frontend/imghost/imghost/Ads/AdManager.swift');
const INFO_PLIST_PATH = resolve(ROOT, 'frontend/imghost/imghost/Info.plist');
const TOKEN_CACHE_PATH = resolve(ROOT, '.admob-tokens.json');

// ─── OAuth constants ──────────────────────────────────────────────────────────

const REDIRECT_PORT = 9004;
const REDIRECT_URI  = `http://localhost:${REDIRECT_PORT}/oauth2callback`;
const SCOPES        = ['https://www.googleapis.com/auth/admob.monetization'];
const ADMOB_BASE    = 'https://admob.googleapis.com/v1beta';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function prompt(question) {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise(resolve => rl.question(question, ans => { rl.close(); resolve(ans.trim()); }));
}

async function admobGet(path, accessToken) {
  const res = await fetch(`${ADMOB_BASE}${path}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  const body = await res.json();
  if (!res.ok) throw Object.assign(new Error(`GET ${path} → ${res.status}`), { status: res.status, body });
  return body;
}

async function admobPost(path, payload, accessToken) {
  const res = await fetch(`${ADMOB_BASE}${path}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const body = await res.json();
  if (!res.ok) throw Object.assign(new Error(`POST ${path} → ${res.status}`), { status: res.status, body });
  return body;
}

// Wait for the OAuth callback on a local HTTP server
function waitForOAuthCode() {
  return new Promise((resolve, reject) => {
    const server = createServer((req, res) => {
      const url = new URL(req.url, `http://localhost:${REDIRECT_PORT}`);
      const code = url.searchParams.get('code');
      const error = url.searchParams.get('error');
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end('<html><body><h2>Authorization complete — you can close this tab.</h2></body></html>');
      server.close();
      if (error) reject(new Error(`OAuth error: ${error}`));
      else resolve(code);
    });
    server.listen(REDIRECT_PORT);
  });
}

// ─── OAuth flow ────────────────────────────────────────────────────────────────

async function getAccessToken(credentials) {
  const { client_id, client_secret } = credentials.installed ?? credentials.web;

  // Reuse cached token if available
  if (existsSync(TOKEN_CACHE_PATH)) {
    try {
      const cached = JSON.parse(readFileSync(TOKEN_CACHE_PATH, 'utf8'));
      if (cached.expiry_date > Date.now() + 60_000) {
        console.log('✓ Using cached OAuth token');
        return cached.access_token;
      }
      // Refresh
      if (cached.refresh_token) {
        const res = await fetch('https://oauth2.googleapis.com/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            client_id, client_secret,
            refresh_token: cached.refresh_token,
            grant_type: 'refresh_token',
          }),
        });
        const data = await res.json();
        if (data.access_token) {
          const updated = {
            ...cached,
            access_token: data.access_token,
            expiry_date: Date.now() + data.expires_in * 1000,
          };
          writeFileSync(TOKEN_CACHE_PATH, JSON.stringify(updated, null, 2));
          console.log('✓ Refreshed OAuth token');
          return data.access_token;
        }
      }
    } catch { /* fall through to full auth */ }
  }

  // Full browser auth
  const authUrl = new URL('https://accounts.google.com/o/oauth2/v2/auth');
  authUrl.searchParams.set('client_id', client_id);
  authUrl.searchParams.set('redirect_uri', REDIRECT_URI);
  authUrl.searchParams.set('response_type', 'code');
  authUrl.searchParams.set('scope', SCOPES.join(' '));
  authUrl.searchParams.set('access_type', 'offline');
  authUrl.searchParams.set('prompt', 'consent');

  console.log('\nOpening browser for Google authorization...');
  console.log('If it does not open automatically, visit:\n', authUrl.toString(), '\n');

  // Try to open the browser
  try {
    const { default: open } = await import('open');
    await open(authUrl.toString());
  } catch {
    // open not installed — user opens manually
  }

  const code = await waitForOAuthCode();

  const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id, client_secret,
      redirect_uri: REDIRECT_URI,
      code,
      grant_type: 'authorization_code',
    }),
  });
  const tokens = await tokenRes.json();
  if (!tokens.access_token) throw new Error(`Token exchange failed: ${JSON.stringify(tokens)}`);

  writeFileSync(TOKEN_CACHE_PATH, JSON.stringify({
    ...tokens,
    expiry_date: Date.now() + tokens.expires_in * 1000,
  }, null, 2));
  console.log('✓ Authorized and token cached to .admob-tokens.json');
  return tokens.access_token;
}

// ─── AdMob helpers ────────────────────────────────────────────────────────────

async function getAccount(token) {
  const data = await admobGet('/accounts', token);
  const accounts = data.account ?? [];
  if (accounts.length === 0) throw new Error('No AdMob accounts found. Complete AdMob account setup at admob.google.com first.');
  if (accounts.length === 1) return accounts[0].name; // e.g. "accounts/pub-XXXXXXXX"
  console.log('\nMultiple AdMob accounts found:');
  accounts.forEach((a, i) => console.log(`  ${i + 1}. ${a.name}  (${a.publisherId})`));
  const choice = await prompt('Select account number: ');
  return accounts[parseInt(choice) - 1].name;
}

async function getOrCreateApp(account, token) {
  // Try to create
  try {
    const app = await admobPost(`/${account}/apps`, {
      platform: 'IOS',
      manualAppInfo: { displayName: 'imghost' },
    }, token);
    console.log(`✓ Created AdMob app: ${app.appId}`);
    return app;
  } catch (err) {
    if (err.status === 403) {
      console.log('⚠  Create app returned 403 (limited access) — listing existing apps instead...');
    } else {
      console.error('Create app error:', err.body ?? err.message);
    }
  }

  // Fallback: list existing apps
  const data = await admobGet(`/${account}/apps`, token);
  const apps = (data.apps ?? []).filter(a => a.platform === 'IOS');
  if (apps.length === 0) {
    console.log('\nNo iOS apps found in AdMob. Create one at admob.google.com then re-run this script.');
    process.exit(1);
  }
  if (apps.length === 1) {
    console.log(`✓ Using existing app: ${apps[0].appId}  (${apps[0].manualAppInfo?.displayName ?? apps[0].linkedAppInfo?.displayName})`);
    return apps[0];
  }
  console.log('\nExisting iOS apps:');
  apps.forEach((a, i) => {
    const name = a.manualAppInfo?.displayName ?? a.linkedAppInfo?.displayName ?? a.name;
    console.log(`  ${i + 1}. ${name}  →  ${a.appId}`);
  });
  const choice = await prompt('Select app number: ');
  return apps[parseInt(choice) - 1];
}

async function getOrCreateAdUnit(account, token, { displayName, adFormat, adTypes }) {
  try {
    const unit = await admobPost(`/${account}/adUnits`, { displayName, adFormat, adTypes }, token);
    console.log(`✓ Created ad unit [${adFormat}]: ${unit.adUnitId}`);
    return unit;
  } catch (err) {
    if (err.status === 403) {
      console.log(`⚠  Create ad unit returned 403 — listing existing ${adFormat} units instead...`);
    } else {
      console.error(`Create ad unit (${adFormat}) error:`, err.body ?? err.message);
    }
  }

  // Fallback: find matching existing unit
  const data = await admobGet(`/${account}/adUnits`, token);
  const units = (data.adUnits ?? []).filter(u => u.adFormat === adFormat);
  if (units.length === 0) {
    console.log(`\nNo ${adFormat} ad units found. Create one at admob.google.com then re-run.`);
    process.exit(1);
  }
  if (units.length === 1) {
    console.log(`✓ Using existing ${adFormat} unit: ${units[0].adUnitId}  (${units[0].displayName})`);
    return units[0];
  }
  console.log(`\nExisting ${adFormat} ad units:`);
  units.forEach((u, i) => console.log(`  ${i + 1}. ${u.displayName}  →  ${u.adUnitId}`));
  const choice = await prompt(`Select ${adFormat} unit number: `);
  return units[parseInt(choice) - 1];
}

// ─── File patchers ────────────────────────────────────────────────────────────

function patchAdManagerSwift(bannerUnitId, interstitialUnitId) {
  let src = readFileSync(AD_MANAGER_PATH, 'utf8');

  // Replace banner test ID
  src = src.replace(
    /static let banner\s+=\s+"ca-app-pub-[^"]+"/,
    `static let banner       = "${bannerUnitId}"`
  );
  // Replace interstitial test ID
  src = src.replace(
    /static let interstitial\s+=\s+"ca-app-pub-[^"]+"/,
    `static let interstitial = "${interstitialUnitId}"`
  );
  // Remove "test" comment
  src = src.replace(/ \/\/ AdMob test banner/g, '');
  src = src.replace(/ \/\/ AdMob test interstitial/g, '');

  writeFileSync(AD_MANAGER_PATH, src);
  console.log('✓ Patched AdManager.swift with real ad unit IDs');
}

function patchInfoPlist(admobAppId) {
  let plist = readFileSync(INFO_PLIST_PATH, 'utf8');

  // Add GADApplicationIdentifier if not present
  if (!plist.includes('GADApplicationIdentifier')) {
    plist = plist.replace(
      '</dict>\n</plist>',
      `\t<key>GADApplicationIdentifier</key>\n\t<string>${admobAppId}</string>\n\t<key>NSUserTrackingUsageDescription</key>\n\t<string>imghost uses this to show relevant ads and measure ad performance.</string>\n</dict>\n</plist>`
    );
    console.log('✓ Added GADApplicationIdentifier and NSUserTrackingUsageDescription to Info.plist');
  } else {
    // Update existing value
    plist = plist.replace(
      /(<key>GADApplicationIdentifier<\/key>\s*<string>)[^<]*(<\/string>)/,
      `$1${admobAppId}$2`
    );
    console.log('✓ Updated GADApplicationIdentifier in Info.plist');
  }

  writeFileSync(INFO_PLIST_PATH, plist);
}

// ─── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  const credentialsPath = process.argv[2];
  if (!credentialsPath) {
    console.error('Usage: node scripts/setup-admob.js path/to/credentials.json');
    console.error('\nGet credentials.json from:');
    console.error('  console.cloud.google.com → APIs & Services → Credentials → Create OAuth 2.0 Client ID (Desktop app)');
    process.exit(1);
  }

  const credentials = JSON.parse(readFileSync(resolve(credentialsPath), 'utf8'));

  console.log('━━━ AdMob Setup ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  // 1. Auth
  const token = await getAccessToken(credentials);

  // 2. Get publisher account
  const account = await getAccount(token);
  console.log(`✓ Using account: ${account}\n`);

  // 3. App
  const app = await getOrCreateApp(account, token);
  const admobAppId = app.appId; // e.g. "ca-app-pub-XXXXXXXX~XXXXXXXXXX"

  // 4. Banner ad unit
  const bannerUnit = await getOrCreateAdUnit(account, token, {
    displayName: 'imghost Banner',
    adFormat: 'BANNER',
    adTypes: ['RICH_MEDIA'],
  });

  // 5. Interstitial ad unit
  const interstitialUnit = await getOrCreateAdUnit(account, token, {
    displayName: 'imghost Interstitial',
    adFormat: 'INTERSTITIAL',
    adTypes: ['RICH_MEDIA', 'VIDEO'],
  });

  // 6. Patch Swift + plist files
  console.log('');
  patchAdManagerSwift(bannerUnit.adUnitId, interstitialUnit.adUnitId);
  patchInfoPlist(admobAppId);

  // 7. Summary
  console.log(`
━━━ Done ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  AdMob App ID      ${admobAppId}
  Banner unit       ${bannerUnit.adUnitId}
  Interstitial unit ${interstitialUnit.adUnitId}

━━━ Remaining manual steps ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. Add the Google Mobile Ads Swift Package in Xcode:
       File → Add Package Dependencies
       URL: https://github.com/googleads/swift-package-manager-google-mobile-ads
       Version: Up to next major from 11.0.0

  2. Build and run on device — confirm banner appears in the History tab
     and an interstitial shows after the first upload.

  3. Update App Store privacy labels to include "Advertising Data" tracking.

`);
}

main().catch(err => {
  console.error('\n✗ Error:', err.message ?? err);
  process.exit(1);
});
