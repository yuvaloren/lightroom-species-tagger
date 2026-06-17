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
if (!img || !fs.existsSync(img)) fail('image not found: ' + img);

// Google UI chrome / boilerplate to drop (the GBIF step would reject it anyway,
// but trimming keeps the candidate set small).
const STOP = new Set(['ai overview', 'visual matches', 'exact matches', 'related searches',
  'search results', 'about this image', 'custom date range', 'choose what you’re giving feedback on',
  'skip to main content', 'accessibility help', 'sign in', 'feedback', 'send feedback', 'translate',
  'footer links', 'privacy', 'terms', 'help', 'update location', 'all', 'ai mode', 'images', 'more']);

// --- opt-in debug / headed mode (see header). Invisible to the plugin: all debug
// output goes to stderr + files; stdout stays the single JSON result line.
const HEADED = process.env.LENS_HEADED === '1';
const DEBUG = HEADED || process.env.LENS_DEBUG === '1';
const KEEPOPEN = HEADED && process.env.LENS_KEEP_OPEN === '1';
const SLOWMO = parseInt(process.env.LENS_SLOWMO || '0', 10) || 0;
const DBGDIR = process.env.LENS_DEBUG_DIR || path.join(os.tmpdir(), 'lens-debug');
const dbg = (...a) => { if (DEBUG) console.error('DEBUG', ...a); };
const dbgWrite = (name, content) => {
  if (!DEBUG) return;
  try { fs.mkdirSync(DBGDIR, { recursive: true }); fs.writeFileSync(path.join(DBGDIR, name), content); }
  catch (e) { console.error('DEBUG write failed', name, e.message); }
};

(async () => {
  if (!hasGeo && place) {
    const c = await geocode(place);
    if (c) { lat = c.lat; lng = c.lng; hasGeo = true; }
  }
  dbg('geo: place=' + place + ' hasGeo=' + hasGeo + ' lat=' + lat + ' lng=' + lng);
  const jar = `/tmp/lens-jar-${process.pid}.txt`;
  fs.writeFileSync(jar, '# Netscape HTTP Cookie File\n' +
    '.google.com\tTRUE\t/\tTRUE\t2147483647\tSOCS\tCAESEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg\n' +
    '.google.com\tTRUE\t/\tFALSE\t2147483647\tCONSENT\tYES+1\n');
  let url;
  try {
    execSync(`curl -sS --compressed -A ${q(UA)} -b ${q(jar)} -c ${q(jar)} -o /dev/null https://www.google.com/`, { timeout: 30000 });
    url = execSync(`curl -sS --compressed -L -A ${q(UA)} -b ${q(jar)} -c ${q(jar)} ` +
      `-H 'Origin: https://www.google.com' -H 'Referer: https://www.google.com/' ` +
      `-F ${q('encoded_image=@' + img + ';type=image/jpeg')} -o /dev/null -w '%{url_effective}' ` +
      `'https://lens.google.com/v3/upload?ep=gsbubb&authuser=0&hl=en&st=${Date.now()}'`, { timeout: 60000 }).toString().trim();
  } catch (e) { try { fs.unlinkSync(jar); } catch (_) {} fail('upload failed: ' + e.message); }
  if (!/[?&]vsrid=/.test(url)) { try { fs.unlinkSync(jar); } catch (_) {} fail('upload rejected (no results URL)'); }
  dbg('results URL:', url);
  dbgWrite('results-url.txt', url);
  if (DEBUG) { try { fs.mkdirSync(DBGDIR, { recursive: true }); fs.copyFileSync(img, path.join(DBGDIR, 'uploaded.jpg')); } catch (e) { dbg('uploaded.jpg copy failed:', e.message); } }

  const cookies = fs.readFileSync(jar, 'utf8').split('\n')
    .map(l => l.replace(/^#HttpOnly_/, '')).filter(l => l && !l.startsWith('#'))
    .map(l => { const p = l.split('\t'); return p.length >= 7 ? { name: p[5], value: p[6], domain: p[0], path: p[2], secure: p[3] === 'TRUE' } : null; })
    .filter(Boolean);
  try { fs.unlinkSync(jar); } catch (_) {}

  let browser;
  try {
    if (KEEPOPEN) {
      // Keep-open: launch a visible Chrome we DON'T own (detached + connect), so it
      // stays open for inspection after this script exits. puppeteer only kills
      // browsers it *launched*, never ones it connect()s to, so node can exit
      // cleanly (the caller — e.g. the Lightroom action — doesn't hang) while the
      // window lives on. Its own --user-data-dir keeps it independent of your Chrome.
      const udd = fs.mkdtempSync(path.join(os.tmpdir(), 'lens-chrome-'));
      const proc = spawn(CHROME, ['--remote-debugging-port=0', '--user-data-dir=' + udd,
        '--no-first-run', '--no-default-browser-check', '--disable-blink-features=AutomationControlled',
        '--lang=en-US', '--start-maximized', 'about:blank'], { detached: true, stdio: 'ignore' });
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
      if (!endpoint) fail('debug: could not start a visible Chrome (no DevToolsActivePort)');
      browser = await puppeteer.connect({ browserURL: endpoint, defaultViewport: null });
      dbg('keep-open: connected to a detached Chrome window —', endpoint);
    } else {
      browser = await puppeteer.launch({
        executablePath: CHROME,
        headless: HEADED ? false : 'new',
        slowMo: SLOWMO,
        dumpio: DEBUG,
        defaultViewport: HEADED ? null : undefined,
        args: ['--no-sandbox', '--disable-blink-features=AutomationControlled', '--lang=en-US',
          ...(HEADED ? ['--start-maximized'] : [])],
      });
    }
    const existingPages = KEEPOPEN ? await browser.pages() : [];
    const page = existingPages.length ? existingPages[0] : await browser.newPage();
    await page.setUserAgent(UA);
    if (!HEADED) await page.setViewport({ width: 1280, height: 1200 });
    await page.evaluateOnNewDocument(() => Object.defineProperty(navigator, 'webdriver', { get: () => undefined }));
    if (hasGeo) {
      try {
        await browser.defaultBrowserContext().overridePermissions('https://www.google.com', ['geolocation']);
        await page.setGeolocation({ latitude: lat, longitude: lng });
      } catch (_) {}
    }
    await page.setCookie(...cookies);
    await page.goto(url, { waitUntil: 'networkidle2', timeout: 45000 }).catch(() => {});
    // wait for the matches AND (if Google is going to show one) the AI Overview,
    // which renders a beat later and is the strongest signal.
    for (let i = 0; i < 15; i++) {
      const r = await page.evaluate(() => ({
        anchors: document.querySelectorAll('a[href]').length,
        ai: /AI Overview/i.test(document.body ? document.body.innerText : ''),
      })).catch(() => ({ anchors: 0, ai: false }));
      if (r.anchors > 40 && r.ai) break;
      if (r.anchors > 40 && i >= 6) break; // no AI overview coming; proceed
      await sleep(1000);
    }
    if (DEBUG) {
      try { fs.mkdirSync(DBGDIR, { recursive: true }); } catch (_) {}
      await page.screenshot({ path: path.join(DBGDIR, 'page.png'), fullPage: true }).catch(() => {});
      try { fs.writeFileSync(path.join(DBGDIR, 'page.html'), await page.content()); } catch (_) {}
      dbg('wrote page.png + page.html to', DBGDIR);
    }
    const data = await page.evaluate(() => {
      const out = [];
      const sources = [];
      // "Noise" sections — Related searches / People also search for / etc. A stray
      // binomial chip there (e.g. "Mustela subpalmata") is NOT about the photo, so it
      // must not be scraped. Find those section headings, treat their subtree as
      // off-limits, and record what we drop. If none are present this is a no-op.
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

      // nearest section heading / aria-label for an element (debug provenance)
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
    out(result); // prints the JSON line and exits; a keep-open (connected) browser is NOT killed
  } catch (e) {
    fail('render failed: ' + e.message);
  } finally {
    // Only close browsers we launched; a keep-open window is connected, so leave it.
    if (browser && !KEEPOPEN) { try { await browser.close(); } catch (_) {} }
  }
})();
