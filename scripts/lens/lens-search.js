#!/usr/bin/env node
/*----------------------------------------------------------------------------
scripts/lens/lens-search.js
Google Lens species search via a real (headless) browser — no paid API, no login.

Google Lens has no anonymous API and its results page is rendered by JavaScript,
so neither curl nor Lightroom's LrHttp can read it. This helper:
  1. uploads the image over curl to lens.google.com/v3/upload (-> a results URL
     + a fresh anonymous session in a cookie jar),
  2. transplants that whole session (incl. HttpOnly cookies) into the user's
     installed Google Chrome via puppeteer-core,
  3. navigates Chrome to the results URL so Chrome runs the JS and renders the
     matches, and scrapes the visible match text.
Output (stdout): JSON { ok, count, strings:[…] } — the strings feed the plugin's
SpeciesParser -> GBIF -> scorer pipeline (which gates precision), so this stays
recall-oriented and tolerant of noise.

Requires: curl, Google Chrome installed, and `npm i` here (puppeteer-core).
Override Chrome with LENS_CHROME=/path/to/chrome. Run from a residential network.
Usage: node lens-search.js <image.jpg> [lat lng | "City, State, Country"]

Interactive (handle Google "unusual traffic" / CAPTCHA / consent challenges):
  LENS_INTERACTIVE=1        run headless first; if the result can't be confidently
                            parsed (a challenge, consent wall, or the enable-JS shell),
                            open a VISIBLE Chrome window so the user can solve it, then
                            auto-detect the real results (or a "Parse results" button)
                            and parse those. A "Cancel" button / timeout aborts. node
                            STAYS ALIVE until then, so the calling task blocks.
  LENS_INTERACTIVE_TIMEOUT  ms to wait for the human before giving up (default 180000).

Troubleshooting (opt-in via env; the plugin pipes stderr to /dev/null and reads
only the single stdout JSON line, so these never affect a normal run):
  LENS_HEADED=1     show a real Chrome window (implies LENS_DEBUG=1)
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

const CHROME = process.env.LENS_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36';
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

// --- opt-in debug / headed / interactive modes (see header). All non-result output
// goes to stderr + files; stdout stays the single JSON result line.
const HEADED = process.env.LENS_HEADED === '1';
const DEBUG = HEADED || process.env.LENS_DEBUG === '1';
const KEEPOPEN = HEADED && process.env.LENS_KEEP_OPEN === '1';
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
  await page.setUserAgent(UA);
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

// Launch a visible Chrome we DON'T own (detached + connect). puppeteer only kills
// browsers it *launched*, never connect()ed ones, so we control teardown explicitly.
async function openDetachedChrome() {
  const udd = fs.mkdtempSync(path.join(os.tmpdir(), 'lens-chrome-'));
  const visArgs = TEST_HEADLESS ? ['--headless=new'] : ['--start-maximized']; // headless for CI tests
  const proc = spawn(CHROME, ['--remote-debugging-port=0', '--user-data-dir=' + udd,
    '--no-first-run', '--no-default-browser-check', '--disable-blink-features=AutomationControlled',
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
  await page.evaluateOnNewDocument(() => {
    const add = () => {
      if (!document.body || document.getElementById('__lens_overlay')) return;
      const bar = document.createElement('div');
      bar.id = '__lens_overlay';
      bar.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#202124;color:#fff;font:14px sans-serif;padding:8px 12px;display:flex;gap:8px;align-items:center;box-shadow:0 2px 8px rgba(0,0,0,.4)';
      const msg = document.createElement('span');
      msg.style.cssText = 'flex:1';
      msg.textContent = 'Species Tagger: complete any Google check, then click “Parse results”.';
      bar.appendChild(msg);
      const mk = (label, bg, fn) => {
        const b = document.createElement('button');
        b.textContent = label;
        b.style.cssText = 'padding:6px 12px;border:0;border-radius:4px;cursor:pointer;background:' + bg + ';color:#fff';
        b.onclick = () => { try { window[fn](); } catch (e) {} };
        return b;
      };
      bar.appendChild(mk('Parse results', '#1a73e8', '__lensParse'));
      bar.appendChild(mk('Cancel', '#d93025', '__lensCancel'));
      document.body.appendChild(bar);
    };
    if (document.body) add();
    else {
      document.addEventListener('DOMContentLoaded', add);
      document.addEventListener('readystatechange', () => { if (document.readyState !== 'loading') add(); });
    }
  });
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
    const jar = `/tmp/lens-jar-${process.pid}.txt`;
    fs.writeFileSync(jar, '# Netscape HTTP Cookie File\n' +
      '.google.com\tTRUE\t/\tTRUE\t2147483647\tSOCS\tCAESEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg\n' +
      '.google.com\tTRUE\t/\tFALSE\t2147483647\tCONSENT\tYES+1\n');
    try {
      execSync(`curl -sS --compressed -A ${q(UA)} -b ${q(jar)} -c ${q(jar)} -o /dev/null https://www.google.com/`, { timeout: 30000 });
      url = execSync(`curl -sS --compressed -L -A ${q(UA)} -b ${q(jar)} -c ${q(jar)} ` +
        `-H 'Origin: https://www.google.com' -H 'Referer: https://www.google.com/' ` +
        `-F ${q('encoded_image=@' + img + ';type=image/jpeg')} -o /dev/null -w '%{url_effective}' ` +
        `'https://lens.google.com/v3/upload?ep=gsbubb&authuser=0&hl=en&st=${Date.now()}'`, { timeout: 60000 }).toString().trim();
    } catch (e) { try { fs.unlinkSync(jar); } catch (_) {} fail('upload failed: ' + e.message); }
    if (!/[?&]vsrid=/.test(url)) { try { fs.unlinkSync(jar); } catch (_) {} fail('upload rejected (no results URL)'); }
    cookies = fs.readFileSync(jar, 'utf8').split('\n')
      .map(l => l.replace(/^#HttpOnly_/, '')).filter(l => l && !l.startsWith('#'))
      .map(l => { const p = l.split('\t'); return p.length >= 7 ? { name: p[5], value: p[6], domain: p[0], path: p[2], secure: p[3] === 'TRUE' } : null; })
      .filter(Boolean);
    try { fs.unlinkSync(jar); } catch (_) {}
  }
  dbg('results URL:', url);
  dbgWrite('results-url.txt', url);
  if (DEBUG) { try { fs.mkdirSync(DBGDIR, { recursive: true }); fs.copyFileSync(img, path.join(DBGDIR, 'uploaded.jpg')); } catch (e) { dbg('uploaded.jpg copy failed:', e.message); } }

  let browser = null, escProc = null;
  // Debug/keep-open opens a visible window from the start; otherwise headless first.
  const startVisible = HEADED || KEEPOPEN;
  try {
    if (startVisible) {
      const d = await openDetachedChrome(); browser = d.browser; escProc = d.proc;
      dbg('opened a visible Chrome window —', d.endpoint);
    } else {
      browser = await puppeteer.launch({
        executablePath: CHROME,
        headless: 'new',
        slowMo: SLOWMO,
        dumpio: DEBUG,
        args: ['--no-sandbox', '--disable-blink-features=AutomationControlled', '--lang=en-US'],
      });
    }
    let pages = await browser.pages();
    let page = pages.length ? pages[0] : await browser.newPage();
    await prepPage(page, cookies, startVisible);

    if (!INTERACTIVE) {
      // Non-interactive (batch / fast path): load + scrape whatever's there (unchanged).
      await loadResults(page, url);
      await emit(page, browser, escProc);
      return;
    }

    if (!startVisible) {
      // Headless first: parse straight away if confident, else escalate to a window.
      await loadResults(page, url);
      const a = await assessConfidence(page);
      dbg('pass-1 confidence:', a.reason);
      if (a.confident) { await emit(page, browser, escProc); return; }
      dbg('not confident (' + a.reason + ') — escalating to a visible window');
      if (DEBUG) { try { fs.writeFileSync(path.join(DBGDIR, 'page-challenge.html'), await page.content()); } catch (_) {} }
      try { await browser.close(); } catch (_) {}
      const d = await openDetachedChrome(); browser = d.browser; escProc = d.proc;
      page = (await browser.pages())[0] || await browser.newPage();
      await prepPage(page, cookies, true);
    }

    // Visible window + interactive: show the control bar, navigate, wait for the human.
    // waitForResult's poll does the readiness-waiting, so just a light navigation here.
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
