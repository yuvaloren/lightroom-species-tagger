#!/usr/bin/env node
/*----------------------------------------------------------------------------
scripts/lens/lens-search.js
Google Lens species search via a real, VISIBLE browser — no paid API, no login.

Google Lens has no anonymous API and its results page is rendered by JavaScript,
so neither curl nor Lightroom's LrHttp can read it. This helper:
  1. uploads the image over curl to lens.google.com/v3/upload (-> a results URL
     + a fresh anonymous session in a cookie jar),
  2. transplants that whole session (incl. HttpOnly cookies) into the user's
     installed Google Chrome via puppeteer-core,
  3. navigates Chrome to the results URL so Chrome runs the JS and renders the
     matches, and scrapes the visible match text.
The Chrome window is always VISIBLE (not headless): we show Google's real page —
ads and all — rather than scraping it invisibly. There is no headless mode for
real runs; the only headless path is the local integration test (LENS_TEST_HEADLESS),
which points at a fake server and never touches Google.
Output (stdout): JSON { ok, count, strings:[…] } — the strings feed the plugin's
SpeciesParser -> GBIF -> scorer pipeline (which gates precision), so this stays
recall-oriented and tolerant of noise.

Requires: curl, Google Chrome installed, and `npm i` here (puppeteer-core).
Override Chrome with LENS_CHROME=/path/to/chrome. Run from a residential network.
Usage: node lens-search.js <image.jpg> [lat lng | "City, State, Country"]

Warm session: a persistent Chrome profile + cookie jar are kept under
~/.cache/speciestagger-lens (override with LENS_CACHE_DIR) and reused across runs
so the identity ages like a returning user rather than a pristine bot each time.
Delete that dir to reset. On a Google "unusual traffic" challenge, a non-interactive
run returns { ok:false, challenged:true } (the caller backs off) rather than
scraping the challenge page; a single-photo run shows the control bar so the human
can solve it in the visible window.

Keep open: with LENS_KEEP_TABS=1 the helper shares ONE persistent visible window
across photos (a normal window WITH a tab strip) — a new tab per image, never closed —
so the result pages stay for follow-ups (e.g. asking Google's AI more). It connects to
an already-open window or launches a detached one on a fixed debug port (LENS_TABS_PORT,
default 9333; separate profile ~/.cache/speciestagger-lens/chrome-profile-open).

Interactive (handle Google "unusual traffic" / CAPTCHA / consent challenges):
  LENS_INTERACTIVE=1        in the visible window, show a "Parse results" / "Cancel"
                            control bar so the user can solve any challenge / consent
                            wall, then auto-detect the real results (or the "Parse
                            results" button) and parse those. A "Cancel" button /
                            timeout aborts. node STAYS ALIVE until then, so the calling
                            task blocks. (Single-photo runs only; a batch is hands-off.)
  LENS_INTERACTIVE_TIMEOUT  ms to wait for the human before giving up (default 180000).

Troubleshooting (opt-in via env; the plugin pipes stderr to /dev/null and reads
only the single stdout JSON line, so these never affect a normal run):
  LENS_HEADED=1     deprecated alias for LENS_DEBUG=1 (the window is always visible now)
  LENS_DEBUG=1      write artifacts to LENS_DEBUG_DIR (default $TMPDIR/lens-debug):
                    results-url.txt, uploaded.jpg, page.png, page.html,
                    strings-sources.json (each scraped string + the page region it
                    came from, with which were excluded as noise), result.json.
                    Debug also goes to stderr.
  LENS_KEEP_OPEN=1  leave a detached Chrome window open for inspection afterwards
                    (node still exits, so callers don't hang — close it yourself)
  LENS_SLOWMO=<ms>  slow Puppeteer actions so you can watch
The ./debug-lens.sh wrapper sets all of these for you.
----------------------------------------------------------------------------*/
const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const puppeteer = require('puppeteer-core');
const { overlayInjector } = require('./overlay-inject');

const CHROME = process.env.LENS_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// Match the UA + Client Hints to the REAL installed Chrome. We MUST override the UA
// because headless Chrome's default UA says "HeadlessChrome/<v>" (a blatant bot tell) —
// but we override to the ACTUAL major version, not a hardcoded stale one, and we set
// userAgentMetadata so Sec-CH-UA / navigator.userAgentData agree with the UA string. A
// string-vs-Client-Hints mismatch (e.g. UA says Chrome/148 while the hints say 149) is
// itself a self-contradiction no real browser produces, and a signal Google can gate on.
function chromeVersion() {
  try {
    const v = execSync(`"${CHROME}" --version`, { timeout: 10000 }).toString();
    const m = v.match(/(\d+)\.\d+\.\d+\.\d+/);
    if (m) return { full: m[0], major: m[1] };
  } catch (_) {}
  return { full: '149.0.0.0', major: '149' }; // sane fallback if the version probe fails
}
const CHROME_VER = chromeVersion();
const UA = `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${CHROME_VER.major}.0.0.0 Safari/537.36`;
// Client Hints consistent with the UA above. The two real brands carry the true major
// version; the third "GREASE" brand is deliberate noise servers are required to ignore.
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
  platform: 'macOS',
  platformVersion: '15.0.0',
  architecture: os.arch() === 'arm64' ? 'arm' : 'x86',
  bitness: '64',
  model: '',
  mobile: false,
};
// Warm-session cache: a PERSISTENT Chrome profile + cookie jar reused across photos and
// runs. A fresh anonymous profile + brand-new cookie jar on every single request is
// itself a bot signal (zero history, identical cold start every time); an aged, reused
// identity looks like a returning user. Override the location with LENS_CACHE_DIR.
const CACHE_DIR = process.env.LENS_CACHE_DIR || path.join(os.homedir(), '.cache', 'speciestagger-lens');
try { fs.mkdirSync(CACHE_DIR, { recursive: true }); } catch (_) {}
const img = process.argv[2];
// optional photo location, to give Lens geographic context so it favours species
// that occur there:
//   node lens-search.js <image> <lat> <lng>        -- exact GPS coordinates
//   node lens-search.js <image> "City, State, …"   -- a place name (geocoded)
let lat = parseFloat(process.argv[3]);
let lng = parseFloat(process.argv[4]);
let hasGeo = Number.isFinite(lat) && Number.isFinite(lng);
const place = (!hasGeo && process.argv[3] && process.argv[3].trim() !== '') ? process.argv[3].trim() : null;

// Geocode a place name to coordinates via OpenStreetMap Nominatim (free, no key).
async function geocode(name) {
  try {
    const u = 'https://nominatim.openstreetmap.org/search?format=json&limit=1&q=' + encodeURIComponent(name);
    const r = await fetch(u, { headers: { 'User-Agent': 'lightroom-species-tagger/0.1 (species id)' } });
    if (!r.ok) return null;
    const j = await r.json();
    if (Array.isArray(j) && j[0]) return { lat: parseFloat(j[0].lat), lng: parseFloat(j[0].lon) };
  } catch (_) {}
  return null;
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
const q = s => "'" + String(s).replace(/'/g, "'\\''") + "'";
const out = o => { console.log(JSON.stringify(o)); process.exit(0); };
const fail = m => out({ ok: false, error: m, strings: [] });
const cancel = () => out({ ok: false, cancelled: true, strings: [] });
if (!img || !fs.existsSync(img)) fail('image not found: ' + img);

// Google UI chrome / boilerplate to drop (the GBIF step would reject it anyway,
// but trimming keeps the candidate set small).
const STOP = new Set(['ai overview', 'visual matches', 'exact matches', 'related searches',
  'search results', 'about this image', 'custom date range', 'choose what you’re giving feedback on',
  'skip to main content', 'accessibility help', 'sign in', 'feedback', 'send feedback', 'translate',
  'footer links', 'privacy', 'terms', 'help', 'update location', 'all', 'ai mode', 'images', 'more']);

// --- opt-in debug / interactive modes (see header). All non-result output goes to stderr
// + files; stdout stays the single JSON result line. Rendering is ALWAYS in a visible
// Chrome window now — we don't run a hidden/headless scrape of Google's page. The only
// headless path left is the local test harness (LENS_TEST_HEADLESS), which never hits Google.
const DEBUG = process.env.LENS_DEBUG === '1' || process.env.LENS_HEADED === '1'; // LENS_HEADED kept as a debug alias
const KEEPOPEN = process.env.LENS_KEEP_OPEN === '1'; // debug: leave the window open afterwards (detached)
// User feature ("keep the browser open"): one persistent, visible window shared across
// photos, a NEW TAB per image, never closed — so result pages stay for follow-ups.
const KEEP_TABS = process.env.LENS_KEEP_TABS === '1';
const INTERACTIVE = process.env.LENS_INTERACTIVE === '1';
const INTERACTIVE_TIMEOUT = parseInt(process.env.LENS_INTERACTIVE_TIMEOUT || '180000', 10) || 180000;
// Test hooks (integration test only): point at a local fake server instead of
// uploading to Google, and allow the "visible" escalation window to run headless.
const TEST_URL = process.env.LENS_TEST_URL || '';
const TEST_HEADLESS = process.env.LENS_TEST_HEADLESS === '1';
const SLOWMO = parseInt(process.env.LENS_SLOWMO || '0', 10) || 0;
const DBGDIR = process.env.LENS_DEBUG_DIR || path.join(os.tmpdir(), 'lens-debug');
const dbg = (...a) => { if (DEBUG) console.error('DEBUG', ...a); };
const dbgWrite = (name, content) => {
  if (!DEBUG) return;
  try { fs.mkdirSync(DBGDIR, { recursive: true }); fs.writeFileSync(path.join(DBGDIR, name), content); }
  catch (e) { console.error('DEBUG write failed', name, e.message); }
};

// Apply the anonymous session to a fresh page: UA, webdriver patch, geolocation, cookies.
async function prepPage(page, cookies, headed) {
  await page.setUserAgent(UA, UA_METADATA);
  if (!headed) await page.setViewport({ width: 1280, height: 1200 });
  await page.evaluateOnNewDocument(() => Object.defineProperty(navigator, 'webdriver', { get: () => undefined }));
  if (hasGeo) {
    try {
      await page.browserContext().overridePermissions('https://www.google.com', ['geolocation']);
      await page.setGeolocation({ latitude: lat, longitude: lng });
    } catch (_) {}
  }
  await page.setCookie(...cookies);
}

// Navigate to the results URL and give the JS a chance to render (matches + the
// later-arriving AI Overview).
async function loadResults(page, url) {
  await page.goto(url, { waitUntil: 'networkidle2', timeout: 45000 }).catch(() => {});
  for (let i = 0; i < 15; i++) {
    const r = await page.evaluate(() => ({
      anchors: document.querySelectorAll('a[href]').length,
      ai: /AI Overview/i.test(document.body ? document.body.innerText : ''),
      challenged: !!document.querySelector('#captcha-form, .g-recaptcha, [data-sitekey], iframe[src*="recaptcha"]'),
    })).catch(() => ({ anchors: 0, ai: false, challenged: false }));
    if (r.challenged) break;             // a challenge won't resolve by waiting — assess + escalate
    if (r.ai) break;                     // AI Overview rendered — results are ready
    if (r.anchors > 40 && i >= 6) break; // lots of anchors, no AI overview coming
    await sleep(1000);
  }
}

// Decide whether we have REAL Lens results or the session was challenged / not ready.
// Collects raw signals in one page.evaluate, then folds in page.url() + frame urls.
async function assessConfidence(page) {
  const sig = await page.evaluate(() => {
    const body = document.body ? document.body.innerText : '';
    const lines = body.split('\n').map(s => s.trim()).filter(Boolean);
    const has = sel => !!document.querySelector(sel);
    return {
      bodyLen: body.length,
      anchors: document.querySelectorAll('a[href]').length,
      captchaForm: has('#captcha-form, form#captcha-form, #recaptcha, .g-recaptcha, [data-sitekey], input[name="g-recaptcha-response"]'),
      recaptchaIframe: has('iframe[src*="recaptcha"], iframe[src*="hcaptcha"], iframe[title*="recaptcha" i]'),
      consentForm: has('form[action*="consent"]'),
      consentText: /before you continue to google/i.test(body),
      titleSorry: /sorry|unusual traffic|before you continue/i.test(document.title || ''),
      noscriptEnableJs: /enable javascript/i.test((document.querySelector('noscript') || {}).textContent || ''),
      aiOverview: lines.some(l => /^AI Overview$/i.test(l)),
      matchesHeading: lines.some(l => /^(visual matches|exact matches)$/i.test(l)),
      bigImgs: [...document.images].filter(im => im.naturalWidth > 32 && im.naturalHeight > 32).length,
      nameLike: new Set(lines.filter(l => /[A-Z][a-z]+ [a-z]{3,}/.test(l))).size,
    };
  }).catch(() => null);
  if (!sig) return { confident: false, reason: 'no-context', signals: null }; // mid-navigation
  const url = page.url();
  const frameUrls = page.frames().map(f => f.url());
  const urlChallenged = [url, ...frameUrls].some(u =>
    /\/sorry\/|sorry\.google\.|consent\.google\.|\/CheckConnection|ipv4check/i.test(u));
  const lostVsrid = !/[?&]vsrid=/.test(url);
  let reason;
  if (urlChallenged || sig.captchaForm || sig.recaptchaIframe || sig.titleSorry) reason = 'challenged';
  else if (sig.consentForm || sig.consentText || /consent\.google\./.test(url)) reason = 'consent';
  else if (sig.noscriptEnableJs && sig.anchors < 15 && !sig.aiOverview) reason = 'shell';
  else {
    const strong = sig.aiOverview || sig.matchesHeading;
    const rich = sig.bigImgs >= 10 && sig.nameLike >= 5 && sig.anchors > 40;
    if ((strong && sig.nameLike >= 5) || rich) reason = 'ok';
    else if (lostVsrid) reason = 'challenged';
    else if (sig.bodyLen < 200 || sig.anchors < 15) reason = 'shell';
    else reason = 'low-signal';
  }
  return { confident: reason === 'ok', reason, signals: sig };
}

// The region-aware scrape: harvest name-like strings, drop Related-searches/People-
// also-search noise (and our own overlay), and extract the AI Overview prose.
async function scrapeRaw(page) {
  return page.evaluate(() => {
    const out = [];
    const sources = [];
    // "Noise" sections — Related searches / People also search for / etc. A stray
    // binomial chip there is NOT about the photo, so it must not be scraped.
    const NOISE = /^(related searches|people also search for|people also ask|people also|more to ask|explore more|more results)\b/i;
    const noiseRoots = [];
    document.querySelectorAll('h1,h2,h3,div[role=heading],[aria-level]').forEach(h => {
      if (NOISE.test((h.innerText || '').trim())) {
        let n = h;
        for (let k = 0; k < 3 && n.parentElement && n.parentElement !== document.body; k++) n = n.parentElement;
        noiseRoots.push(n);
      }
    });
    const inNoise = el => noiseRoots.some(r => r.contains(el));
    const noiseLines = new Set();
    noiseRoots.forEach(r => (r.innerText || '').split('\n').forEach(l => { l = l.trim(); if (l) noiseLines.add(l); }));

    const regionOf = el => {
      for (let n = el, up = 0; n && up < 8; up++, n = n.parentElement) {
        for (let s = n, k = 0; s && k < 6; k++, s = s.previousElementSibling) {
          if (s.matches && s.matches('h1,h2,h3,div[role=heading],[aria-level]')) {
            const t = (s.innerText || '').replace(/\s+/g, ' ').trim();
            if (t && t.length <= 60) return t;
          }
        }
        const al = n.getAttribute && (n.getAttribute('aria-label') || n.getAttribute('data-attrid'));
        if (al) return al;
      }
      return '';
    };

    const push = (t, el) => {
      if (el && el.closest && el.closest('#__lens_overlay')) return; // never scrape our own UI
      t = (t || '').replace(/\s+/g, ' ').trim();
      if (!(t.length >= 4 && t.length <= 200 && /[a-z]/.test(t))) return;
      const region = el ? regionOf(el) : 'body-text';
      const noise = el ? (inNoise(el) || NOISE.test(region)) : noiseLines.has(t);
      sources.push({ text: t, region: region, excluded: noise });
      if (!noise) out.push(t);
    };

    document.querySelectorAll('h1,h2,h3,div[role=heading],[aria-level]').forEach(e => push(e.innerText, e));
    document.querySelectorAll('a[href]').forEach(a => { const t = a.innerText; if (t && t.split(' ').length <= 14) push(t, a); });
    const lines = (document.body ? document.body.innerText : '').split('\n').map(s => s.trim());
    lines.forEach(line => { if (/[A-Z][a-z]+ [a-z]{3,}/.test(line)) push(line, null); });

    // The "AI Overview" block is Google's single authoritative answer (it names
    // the species + binomial). Grab the prose lines right after that heading.
    const overview = [];
    const i = lines.findIndex(l => /^AI Overview$/i.test(l));
    if (i >= 0) {
      for (let j = i + 1; j < lines.length && overview.length < 8; j++) {
        const l = lines[j];
        if (!l) { if (overview.length) break; else continue; }
        if (/^(Show more|Visual matches|Related searches|People also|From sources|Feedback|Search Results|All|Exact matches|About this image)/i.test(l)) break;
        if (l.length > 250) break;
        overview.push(l);
      }
    }
    return { strings: out, sources: sources, overview: overview.join(' ') };
  });
}

// "Keep browser open" mode: ONE persistent, visible Chrome (a normal window WITH a tab
// strip — tabs are the point here) shared across photos via a fixed remote-debug port.
// Each photo opens a new tab in it and never closes it, so the user keeps the result
// pages for follow-ups (e.g. asking Google's AI more). Connect to an already-open one,
// else launch a detached one that survives this (per-photo) process exiting. Because it's
// a connect()ed browser, puppeteer never kills it — process exit just drops the socket.
const TABS_PORT = parseInt(process.env.LENS_TABS_PORT || '9333', 10) || 9333;
const TABS_PROFILE = path.join(CACHE_DIR, 'chrome-profile-open');
async function connectTabbed() {
  const tryConnect = () => puppeteer.connect({ browserURL: 'http://127.0.0.1:' + TABS_PORT, defaultViewport: null });
  try { return await tryConnect(); } catch (_) {}   // an existing keep-open window?
  try { fs.mkdirSync(TABS_PROFILE, { recursive: true }); } catch (_) {}
  const visArgs = TEST_HEADLESS ? ['--headless=new'] : []; // headless only for the integration test
  const proc = spawn(CHROME, ['--remote-debugging-port=' + TABS_PORT, '--user-data-dir=' + TABS_PROFILE,
    '--no-first-run', '--no-default-browser-check', '--lang=en-US', '--window-size=1280,960',
    ...visArgs, 'about:blank'], { detached: true, stdio: 'ignore' });
  proc.unref();
  for (let i = 0; i < 100; i++) { await sleep(100); try { return await tryConnect(); } catch (_) {} }
  throw new Error('could not start the keep-open Chrome window (port ' + TABS_PORT + ')');
}

// Launch a visible Chrome we DON'T own (detached + connect). puppeteer only kills
// browsers it *launched*, never connect()ed ones, so we control teardown explicitly.
async function openDetachedChrome() {
  const udd = fs.mkdtempSync(path.join(os.tmpdir(), 'lens-chrome-'));
  const visArgs = TEST_HEADLESS ? ['--headless=new'] : ['--start-maximized']; // headless for CI tests
  // NB: no --disable-blink-features=AutomationControlled here — recent Chrome shows
  // an "unsupported command-line flag" warning bar for it on a visible window. We get
  // the same effect (hidden navigator.webdriver) from prepPage's evaluateOnNewDocument.
  const proc = spawn(CHROME, ['--remote-debugging-port=0', '--user-data-dir=' + udd,
    '--no-first-run', '--no-default-browser-check',
    '--lang=en-US', ...visArgs, 'about:blank'], { detached: true, stdio: 'ignore' });
  proc.unref();
  const portFile = path.join(udd, 'DevToolsActivePort');
  let endpoint;
  for (let i = 0; i < 100 && !endpoint; i++) {
    if (fs.existsSync(portFile)) {
      const p = fs.readFileSync(portFile, 'utf8').split('\n');
      if (p[0] && p[0].trim()) endpoint = 'http://127.0.0.1:' + p[0].trim();
    }
    if (!endpoint) await sleep(100);
  }
  if (!endpoint) throw new Error('could not start a visible Chrome (no DevToolsActivePort)');
  const browser = await puppeteer.connect({ browserURL: endpoint, defaultViewport: null });
  return { browser, proc, endpoint };
}

// Inject the Parse/Cancel control bar. Bound ONCE (exposeFunction re-binds window.*
// on every navigation automatically) + re-added on every document so it survives
// the navigations a CAPTCHA/consent solve causes.
async function installInteractive(page) {
  let resolveParse, resolveCancel;
  const parseClicked = new Promise(r => (resolveParse = r));
  const cancelClicked = new Promise(r => (resolveCancel = r));
  await page.exposeFunction('__lensParse', () => resolveParse({ via: 'parse' }));
  await page.exposeFunction('__lensCancel', () => resolveCancel({ via: 'cancel' }));
  // overlayInjector (./overlay-inject) adds the control bar to the TOP frame only —
  // see that module + test/overlay-frame.test.js for why subframes must be skipped.
  await page.evaluateOnNewDocument(overlayInjector);
  return { parseClicked, cancelClicked };
}

// Wait for the real results, racing: stable auto-detect / Parse click / Cancel click /
// timeout. assessConfidence is polled (it tolerates mid-navigation) and must read
// confident 3x in a row (~2s) so we never scrape a half-rendered post-CAPTCHA page.
async function waitForResult(page, parseClicked, cancelClicked) {
  let settled = false;
  const autoDetected = (async () => {
    let streak = 0;
    while (!settled) {
      await sleep(700);
      let ok = false;
      try { ok = (await assessConfidence(page)).confident; } catch (_) { ok = false; }
      streak = ok ? streak + 1 : 0;
      if (streak >= 3) return { via: 'auto' };
    }
    return new Promise(() => {}); // never resolves once another branch wins
  })();
  let timer;
  const timedOut = new Promise(r => { timer = setTimeout(() => r({ via: 'timeout' }), INTERACTIVE_TIMEOUT); });
  const outcome = await Promise.race([autoDetected, parseClicked, cancelClicked, timedOut]);
  settled = true; clearTimeout(timer);
  return outcome;
}

// Close down per the launch mode: a connected detached window is disconnected (and
// killed unless KEEPOPEN); a launched headless browser is killed by puppeteer on exit.
function teardown(browser, escProc) {
  try {
    if (escProc) {
      try { if (browser) browser.disconnect(); } catch (_) {}
      if (!KEEPOPEN) { try { process.kill(-escProc.pid, 'SIGTERM'); } catch (_) {} }
    }
  } catch (_) {}
}

// Final step shared by every success path: drop the overlay, capture debug artifacts,
// scrape, build the result, tear down, and emit the single JSON line.
async function emit(page, browser, escProc) {
  await page.evaluate(() => { const o = document.getElementById('__lens_overlay'); if (o) o.remove(); }).catch(() => {});
  if (DEBUG) {
    try { fs.mkdirSync(DBGDIR, { recursive: true }); } catch (_) {}
    await page.screenshot({ path: path.join(DBGDIR, 'page.png'), fullPage: true }).catch(() => {});
    try { fs.writeFileSync(path.join(DBGDIR, 'page.html'), await page.content()); } catch (_) {}
  }
  const data = await scrapeRaw(page);
  const seen = new Set(); const clean = [];
  for (const s of data.strings) { const k = s.toLowerCase(); if (STOP.has(k) || seen.has(k)) continue; seen.add(k); clean.push(s); }
  const result = { ok: true, count: clean.length, overview: data.overview || '', strings: clean.slice(0, 80) };
  if (DEBUG) {
    dbgWrite('strings-sources.json', JSON.stringify(data.sources || [], null, 2));
    dbgWrite('result.json', JSON.stringify(result, null, 2));
    const dropped = (data.sources || []).filter(s => s.excluded).length;
    dbg('scraped ' + clean.length + ' strings; excluded ' + dropped + ' from noise regions; AI overview ' + (result.overview ? 'present' : 'EMPTY'));
  }
  if (KEEPOPEN) console.error('DEBUG: Chrome window left open for inspection — close it when done.');
  teardown(browser, escProc);
  out(result);
}

(async () => {
  if (!hasGeo && place) {
    const c = await geocode(place);
    if (c) { lat = c.lat; lng = c.lng; hasGeo = true; }
  }
  dbg('geo: place=' + place + ' hasGeo=' + hasGeo + ' lat=' + lat + ' lng=' + lng);
  let url, cookies = [];
  if (TEST_URL) {
    // Test mode: skip the upload, point Chrome at the local fake server.
    url = TEST_URL;
    dbg('TEST mode: pointing at', url);
  } else {
    // Persistent jar (warm session): reuse + age the cookies across runs. Seed the
    // consent cookies only when first creating it; thereafter let curl read/refresh it.
    const jar = path.join(CACHE_DIR, 'cookies.txt');
    if (!fs.existsSync(jar)) {
      fs.writeFileSync(jar, '# Netscape HTTP Cookie File\n' +
        '.google.com\tTRUE\t/\tTRUE\t2147483647\tSOCS\tCAESEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg\n' +
        '.google.com\tTRUE\t/\tFALSE\t2147483647\tCONSENT\tYES+1\n');
    }
    try {
      execSync(`curl -sS --compressed -A ${q(UA)} -b ${q(jar)} -c ${q(jar)} -o /dev/null https://www.google.com/`, { timeout: 30000 });
      url = execSync(`curl -sS --compressed -L -A ${q(UA)} -b ${q(jar)} -c ${q(jar)} ` +
        `-H 'Origin: https://www.google.com' -H 'Referer: https://www.google.com/' ` +
        `-F ${q('encoded_image=@' + img + ';type=image/jpeg')} -o /dev/null -w '%{url_effective}' ` +
        `'https://lens.google.com/v3/upload?ep=gsbubb&authuser=0&hl=en&st=${Date.now()}'`, { timeout: 60000 }).toString().trim();
    } catch (e) { fail('upload failed: ' + e.message); }              // keep the jar (it's persistent/warm)
    if (!/[?&]vsrid=/.test(url)) fail('upload rejected (no results URL)');
    cookies = fs.readFileSync(jar, 'utf8').split('\n')
      .map(l => l.replace(/^#HttpOnly_/, '')).filter(l => l && !l.startsWith('#'))
      .map(l => { const p = l.split('\t'); return p.length >= 7 ? { name: p[5], value: p[6], domain: p[0], path: p[2], secure: p[3] === 'TRUE' } : null; })
      .filter(Boolean);
  }
  dbg('results URL:', url);
  dbgWrite('results-url.txt', url);
  if (DEBUG) { try { fs.mkdirSync(DBGDIR, { recursive: true }); fs.copyFileSync(img, path.join(DBGDIR, 'uploaded.jpg')); } catch (e) { dbg('uploaded.jpg copy failed:', e.message); } }

  let browser = null, escProc = null, page = null;
  // ALWAYS render in a VISIBLE Chrome window so Google's actual page — ads and all — is
  // shown while we work; we do not run a hidden headless scrape. LENS_TEST_HEADLESS is the
  // sole headless path (local test server). Three window modes:
  //   KEEP_TABS : one persistent window, a NEW TAB per image, never closed (user feature).
  //   KEEPOPEN  : a detached window kept open for inspection (debug).
  //   default   : a small chrome-less --app popup that closes after each image.
  try {
    if (KEEP_TABS) {
      browser = await connectTabbed();             // connected (not launched): survives our exit
      const open = await browser.pages();
      page = open.find(p => p.url() === 'about:blank') || await browser.newPage(); // a tab for this image
    } else if (KEEPOPEN) {
      const d = await openDetachedChrome(); browser = d.browser; escProc = d.proc;
      dbg('opened a detached visible Chrome window —', d.endpoint);
      page = (await browser.pages())[0] || await browser.newPage();
    } else {
      browser = await puppeteer.launch({
        executablePath: CHROME,
        headless: TEST_HEADLESS ? 'new' : false,   // visible for real use; headless ONLY for the local test harness
        slowMo: SLOWMO,
        dumpio: DEBUG,
        // Persistent profile (warm session): aged NID/history across runs, not a pristine
        // bot profile each time. Batch photos run sequentially so there's no dir contention.
        userDataDir: path.join(CACHE_DIR, 'chrome-profile'),
        defaultViewport: null,                       // viewport follows the real window size
        // App-style popup window: small, and with no tabs / toolbar / bookmark bar — just
        // the page. We open it on about:blank so prepPage can set the UA/cookies/geo before
        // we navigate to the results URL (the app window stays chromeless across that nav).
        args: ['--no-sandbox', '--no-first-run', '--no-default-browser-check', '--lang=en-US']
          .concat(TEST_HEADLESS ? [] : ['--app=about:blank', '--window-size=1280,960']),
      });
      page = (await browser.pages())[0] || await browser.newPage();
    }
    const headed = !TEST_HEADLESS;
    await prepPage(page, cookies, headed);

    if (!INTERACTIVE) {
      // Non-interactive (batch): load, then bail CLEARLY on a challenge so the caller can
      // back off — never scrape the /sorry or consent page as if it were results (that
      // returned the captcha boilerplate as fake species candidates).
      await loadResults(page, url);
      const a = await assessConfidence(page);
      if (a.reason === 'challenged' || a.reason === 'consent') {
        dbg('non-interactive challenge:', a.reason, '— signalling the caller to back off');
        if (DEBUG) { try { fs.mkdirSync(DBGDIR, { recursive: true }); fs.writeFileSync(path.join(DBGDIR, 'page-challenge.html'), await page.content()); } catch (_) {} }
        teardown(browser, escProc);
        out({ ok: false, challenged: true, reason: a.reason, strings: [] });
        return;
      }
      await emit(page, browser, escProc);
      return;
    }

    // Interactive (single photo): we're already visible, so show the control bar, navigate,
    // and wait for the human to solve any Google check (or auto-detect real results).
    const { parseClicked, cancelClicked } = await installInteractive(page);
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 }).catch(() => {});
    const outcome = await waitForResult(page, parseClicked, cancelClicked);
    dbg('interactive outcome:', outcome.via);
    if (outcome.via === 'cancel' || outcome.via === 'timeout') { teardown(browser, escProc); cancel(); return; }
    await emit(page, browser, escProc);
  } catch (e) {
    teardown(browser, escProc);
    fail('render failed: ' + e.message);
  }
})();
