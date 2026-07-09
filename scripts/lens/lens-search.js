#!/usr/bin/env node
/*----------------------------------------------------------------------------
scripts/lens/lens-search.js
Assistive Google Lens helper — no scraping, no paid API, no login.

For one photo it uploads the image to Google Lens the way the Lens website does, opens
the results in the user's VISIBLE Chrome, and injects a small bottom bar with a Tag +
Skip button and an "m of n" counter. The USER reads Google's real page and highlights the
species name; pressing Tag records ONLY window.getSelection(). This helper never reads or
scrapes Google's results — it returns just the string the user highlighted.

Multi-photo: ONE persistent Chrome window is reused across photos (a fresh tab per photo,
the previous one closed), on a fixed remote-debug port. The window is launched detached so
it survives each per-photo invocation, and is closed cleanly at the end (LENS_ASSIST_CLOSE)
so Chrome never shows a "didn't shut down correctly" restore prompt. The overlay talks to
Node through page globals (window.__stTag / window.__stSkip) that Node POLLS — no
exposeFunction, so it keeps working across those reconnects.

Output (stdout): a single JSON line — { ok:true, name } | { ok:false, cancelled|error }.

Requires: Google Chrome installed, and `npm i` here (puppeteer-core). Override Chrome
with LENS_CHROME=/path/to/chrome. Run from a residential network. The image is uploaded
IN this Chrome (same session that views the results) — no separate curl session, and no
fabricated consent cookie; any consent screen is handled by the user in the visible window.

Env:
  LENS_ASSIST_POS      text shown in the bar, e.g. "Photo 2 of 5"
  LENS_ASSIST_CLOSE=1  connect to the reuse window and close it cleanly, then exit
  LENS_TABS_PORT       remote-debug port for the reuse window (default 9333)
  LENS_CACHE_DIR       persistent profile + cookie jar (default ~/.cache/speciestagger-lens)
  LENS_INTERACTIVE_TIMEOUT  ms to wait for a Tag/Skip before giving up (default 180000)
  Test/debug: LENS_TEST_URL (skip upload, point at a local fake server),
  LENS_TEST_HEADLESS=1 (headless — the ONLY headless path; local test only), LENS_DEBUG=1.
----------------------------------------------------------------------------*/
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const puppeteer = require('puppeteer-core');
const { assistOverlayInjector } = require('./overlay-inject');
const { findChrome, chromeVersion } = require('./find-chrome');

const IS_WIN = process.platform === 'win32';

// Locate the installed Google Chrome (shared with the tests). Override with LENS_CHROME.
const CHROME = findChrome();

// Match the UA + Client Hints to the REAL installed Chrome so Google serves the normal
// results page (a HeadlessChrome UA, or a UA whose major disagrees with the Client Hints,
// gets a degraded/blocked variant). About rendering the real page correctly, not disguise —
// the window is visible the whole time. chromeVersion() never launches Chrome on Windows
// (reading `chrome --version` there pops a phantom window) — see find-chrome.js.
const CHROME_VER = chromeVersion(CHROME);
const PLATFORM = IS_WIN ? { ua: 'Windows NT 10.0; Win64; x64', ch: 'Windows', chVer: '10.0.0' }
  : process.platform === 'darwin' ? { ua: 'Macintosh; Intel Mac OS X 10_15_7', ch: 'macOS', chVer: '15.0.0' }
  : { ua: 'X11; Linux x86_64', ch: 'Linux', chVer: '' };
const UA = `Mozilla/5.0 (${PLATFORM.ua}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${CHROME_VER.major}.0.0.0 Safari/537.36`;
const UA_METADATA = {
  brands: [
    { brand: 'Chromium', version: CHROME_VER.major },
    { brand: 'Google Chrome', version: CHROME_VER.major },
    { brand: 'Not?A_Brand', version: '24' },
  ],
  fullVersion: CHROME_VER.full,
  fullVersionList: [
    { brand: 'Chromium', version: CHROME_VER.full },
    { brand: 'Google Chrome', version: CHROME_VER.full },
    { brand: 'Not?A_Brand', version: '24.0.0.0' },
  ],
  platform: PLATFORM.ch,
  platformVersion: PLATFORM.chVer,
  architecture: os.arch() === 'arm64' ? 'arm' : 'x86',
  bitness: '64',
  model: '',
  mobile: false,
};

// Session-reuse cache: a persistent profile + cookie jar reused across photos and runs, so
// each photo doesn't start from a cold cookie/consent screen. Override with LENS_CACHE_DIR.
const CACHE_DIR = process.env.LENS_CACHE_DIR || path.join(os.homedir(), '.cache', 'speciestagger-lens');
try { fs.mkdirSync(CACHE_DIR, { recursive: true }); } catch (_) {}

const img = process.argv[2];
const POS = (process.env.LENS_ASSIST_POS || '').trim();
const CLOSE = process.env.LENS_ASSIST_CLOSE === '1';
const TEST_URL = process.env.LENS_TEST_URL || '';
const TEST_HEADLESS = process.env.LENS_TEST_HEADLESS === '1';
const TIMEOUT = parseInt(process.env.LENS_INTERACTIVE_TIMEOUT || '180000', 10) || 180000;
const DEBUG = process.env.LENS_DEBUG === '1';
const dbg = (...a) => { if (DEBUG) console.error('DEBUG', ...a); };

const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = o => { console.log(JSON.stringify(o)); process.exit(0); };
const fail = m => out({ ok: false, error: m });
const skip = () => out({ ok: false, cancelled: true });

const TABS_PORT = parseInt(process.env.LENS_TABS_PORT || '9333', 10) || 9333;
const TABS_PROFILE = path.join(CACHE_DIR, 'chrome-profile-assist');

// Chrome shows a "didn't shut down correctly / restore pages?" bubble on startup when the
// profile's last recorded exit wasn't "Normal" — and ONE unclean exit (a crash, a killed
// process, or quitting Lightroom mid-run) poisons every launch after it. So before each
// launch, force the profile's exit state to clean in its Preferences file. This is more
// reliable than a flag (and avoids the "unsupported flag" warning bar on a visible window).
function markProfileClean(profileDir) {
  for (const pref of [path.join(profileDir, 'Default', 'Preferences'), path.join(profileDir, 'Preferences')]) {
    try {
      if (!fs.existsSync(pref)) continue;
      const j = JSON.parse(fs.readFileSync(pref, 'utf8'));
      j.profile = j.profile || {};
      j.profile.exit_type = 'Normal';
      j.profile.exited_cleanly = true;
      fs.writeFileSync(pref, JSON.stringify(j));
    } catch (_) { /* best-effort */ }
  }
}

// Connect to the reuse window on TABS_PORT; launch a detached one if none is open (and
// launchIfAbsent). Detached so it survives THIS per-photo process exiting; puppeteer never
// kills a connect()ed browser, so we close it explicitly at the end (see CLOSE).
async function connectWindow(launchIfAbsent) {
  const tryConnect = () => puppeteer.connect({ browserURL: 'http://127.0.0.1:' + TABS_PORT, defaultViewport: null });
  try { return await tryConnect(); } catch (_) {}
  if (!launchIfAbsent) return null;
  try { fs.mkdirSync(TABS_PROFILE, { recursive: true }); } catch (_) {}
  markProfileClean(TABS_PROFILE); // never nag about a previous unclean exit
  const visArgs = TEST_HEADLESS ? ['--headless=new', '--no-sandbox'] : ['--window-size=1280,960'];
  const proc = spawn(CHROME, ['--remote-debugging-port=' + TABS_PORT, '--user-data-dir=' + TABS_PROFILE,
    '--no-first-run', '--no-default-browser-check', '--lang=en-US', ...visArgs, 'about:blank'],
    { detached: true, stdio: 'ignore' });
  proc.unref();
  for (let i = 0; i < 100; i++) { await sleep(100); try { return await tryConnect(); } catch (_) {} }
  throw new Error('could not start the assist Chrome window (port ' + TABS_PORT + ')');
}

// UA + the anonymous session cookies on a fresh page. No geolocation (measured to hurt),
// no navigator.webdriver spoof (measured to make no difference) — the window is visible.
async function prepPage(page, cookies) {
  await page.setUserAgent(UA, UA_METADATA);
  if (TEST_HEADLESS) await page.setViewport({ width: 1280, height: 1200 });
  if (cookies && cookies.length) { try { await page.setCookie(...cookies); } catch (_) {} }
}

// Upload the image INSIDE the visible Chrome — the same session that then views the
// results. We open Lens, build our OWN tiny upload form (createElement only, never
// innerHTML) that posts to the public upload endpoint the website uses, let puppeteer put
// the file on it, and submit: the browser navigates to the results in-session, exactly the
// way a manual upload does. This replaces an out-of-band curl upload whose separate cookie
// jar Google no longer honors on this fresh profile ("image not associated with your
// account"). No scraping — we still read only the user's selection. Returns nothing; the
// page is left on the Lens results (or fails hard if no results URL came back).
async function uploadInBrowser(page, imgPath) {
  // Warm up on google.com in the (persistent, visible) profile so the upload runs inside an
  // ordinary session — cookies are .google.com-wide, so they reach lens.google.com too. We
  // do NOT fabricate a consent cookie: if Google shows a consent screen (mostly EU) the user
  // handles it in the visible window and the persistent profile remembers it thereafter.
  await page.goto('https://www.google.com/', { waitUntil: 'domcontentloaded', timeout: 45000 }).catch(() => {});
  // Build our OWN upload form (createElement only, never innerHTML) posting to the public
  // endpoint the website uses, and submit it as a top-level navigation to the results.
  await page.evaluate(() => {
    const f = document.createElement('form');
    f.id = '__stUploadForm';
    f.method = 'POST';
    f.enctype = 'multipart/form-data';
    f.action = 'https://lens.google.com/v3/upload?ep=gsbubb&authuser=0&hl=en&st=' + Date.now();
    const i = document.createElement('input');
    i.type = 'file';
    i.name = 'encoded_image';
    i.id = '__stUploadFile';
    f.appendChild(i);
    document.documentElement.appendChild(f);
  });
  const input = await page.$('#__stUploadFile');
  if (!input) return fail('could not build the Lens upload form');
  await input.uploadFile(imgPath);
  await Promise.all([
    page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: 60000 }).catch(() => {}),
    page.evaluate(() => document.getElementById('__stUploadForm').submit()),
  ]);
  const landed = page.url();
  dbg('in-browser upload landed on:', landed);
  if (!/[?&]vsrid=/.test(landed)) fail('upload rejected (no results URL) — landed on ' + landed);
}

// Poll the page for the user's Tag (window.__stTag) or Skip (window.__stSkip), or time out.
// No exposeFunction, so this keeps working across window reconnects and page navigations.
async function waitForTag(page) {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    let s = null;
    try { s = await page.evaluate(() => ({ tag: window.__stTag || null, skip: !!window.__stSkip })); }
    catch (_) { /* mid-navigation — try again */ }
    if (s && s.tag) return { via: 'tag', name: String(s.tag).trim() };
    if (s && s.skip) return { via: 'skip' };
    await sleep(300);
  }
  return { via: 'timeout' };
}

(async () => {
  // Close command: connect to the reuse window and shut it down cleanly (no restore prompt).
  if (CLOSE) {
    const b = await connectWindow(false);
    if (b) { try { await b.close(); } catch (_) {} }
    out({ ok: true, closed: true });
    return;
  }

  if (!img || (!TEST_URL && !fs.existsSync(img))) fail('image not found: ' + img);

  let browser = null;
  try {
    browser = await connectWindow(true);
    // Reuse ONE window: open a fresh tab for this photo, close the others, so there's a
    // single visible tab and the overlay's evaluateOnNewDocument can't accumulate.
    const page = await browser.newPage();
    for (const p of await browser.pages()) { if (p !== page) { try { await p.close(); } catch (_) {} } }
    await prepPage(page);
    await page.evaluateOnNewDocument(assistOverlayInjector, POS || null);
    // TEST_URL points at a local fake Google (offline tests); otherwise upload in-session.
    if (TEST_URL) {
      await page.goto(TEST_URL, { waitUntil: 'domcontentloaded', timeout: 45000 }).catch(() => {});
    } else {
      await uploadInBrowser(page, img);
    }
    const outcome = await waitForTag(page);
    dbg('assist outcome:', outcome.via, outcome.name || '');
    try { browser.disconnect(); } catch (_) {}   // leave the window open for the next photo / close step
    if (outcome.via === 'tag' && outcome.name) out({ ok: true, name: outcome.name });
    else if (outcome.via === 'skip') skip();
    else out({ ok: false, error: 'no species tagged (timed out waiting for a selection)' });
  } catch (e) {
    try { if (browser) browser.disconnect(); } catch (_) {}
    fail('assist failed: ' + (e && e.message ? e.message : String(e)));
  }
})();
