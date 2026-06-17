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
    await page.setCookie(...cookies);
    await page.goto(url, { waitUntil: 'networkidle2', timeout: 45000 }).catch(() => {});
    for (let i = 0; i < 12; i++) {
      const n = await page.evaluate(() => document.querySelectorAll('a[href]').length).catch(() => 0);
      if (n > 40) break;
      await sleep(1000);
    }
    let strings = await page.evaluate(() => {
      const out = [];
      const push = t => { t = (t || '').replace(/\s+/g, ' ').trim(); if (t.length >= 4 && t.length <= 160 && /[a-z]/.test(t)) out.push(t); };
      document.querySelectorAll('h1,h2,h3,div[role=heading],[aria-level]').forEach(e => push(e.innerText));
      document.querySelectorAll('a[href]').forEach(a => { const t = a.innerText; if (t && t.split(' ').length <= 14) push(t); });
      (document.body ? document.body.innerText : '').split('\n').forEach(line => {
        if (/[A-Z][a-z]+ [a-z]{3,}/.test(line)) push(line); // lines containing a possible binomial
      });
      return out;
    });
    // dedupe + drop UI chrome
    const seen = new Set(); const clean = [];
    for (const s of strings) { const k = s.toLowerCase(); if (STOP.has(k) || seen.has(k)) continue; seen.add(k); clean.push(s); }
    out({ ok: true, count: clean.length, strings: clean.slice(0, 80) });
  } catch (e) {
    fail('render failed: ' + e.message);
  } finally {
    if (browser) await browser.close();
  }
})();
