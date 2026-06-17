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
Usage: node lens-search.js <image.jpg>
----------------------------------------------------------------------------*/
const { execSync } = require('child_process');
const fs = require('fs');
const puppeteer = require('puppeteer-core');

const CHROME = process.env.LENS_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36';
const img = process.argv[2];
// optional photo location: node lens-search.js <image> [lat] [lng] — gives Lens
// geographic context so it favours species that occur there.
const lat = parseFloat(process.argv[3]);
const lng = parseFloat(process.argv[4]);
const hasGeo = Number.isFinite(lat) && Number.isFinite(lng);
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

(async () => {
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

  const cookies = fs.readFileSync(jar, 'utf8').split('\n')
    .map(l => l.replace(/^#HttpOnly_/, '')).filter(l => l && !l.startsWith('#'))
    .map(l => { const p = l.split('\t'); return p.length >= 7 ? { name: p[5], value: p[6], domain: p[0], path: p[2], secure: p[3] === 'TRUE' } : null; })
    .filter(Boolean);
  try { fs.unlinkSync(jar); } catch (_) {}

  let browser;
  try {
    browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new',
      args: ['--no-sandbox', '--disable-blink-features=AutomationControlled', '--lang=en-US'] });
    const page = await browser.newPage();
    await page.setUserAgent(UA);
    await page.setViewport({ width: 1280, height: 1200 });
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
    const data = await page.evaluate(() => {
      const out = [];
      const push = t => { t = (t || '').replace(/\s+/g, ' ').trim(); if (t.length >= 4 && t.length <= 200 && /[a-z]/.test(t)) out.push(t); };
      document.querySelectorAll('h1,h2,h3,div[role=heading],[aria-level]').forEach(e => push(e.innerText));
      document.querySelectorAll('a[href]').forEach(a => { const t = a.innerText; if (t && t.split(' ').length <= 14) push(t); });
      const lines = (document.body ? document.body.innerText : '').split('\n').map(s => s.trim());
      lines.forEach(line => { if (/[A-Z][a-z]+ [a-z]{3,}/.test(line)) push(line); });

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
      return { strings: out, overview: overview.join(' ') };
    });
    const seen = new Set(); const clean = [];
    for (const s of data.strings) { const k = s.toLowerCase(); if (STOP.has(k) || seen.has(k)) continue; seen.add(k); clean.push(s); }
    out({ ok: true, count: clean.length, overview: data.overview || '', strings: clean.slice(0, 80) });
  } catch (e) {
    fail('render failed: ' + e.message);
  } finally {
    if (browser) await browser.close();
  }
})();
