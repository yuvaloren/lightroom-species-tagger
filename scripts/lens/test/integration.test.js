#!/usr/bin/env node
/*----------------------------------------------------------------------------
scripts/lens/test/integration.test.js
Automated test for the ASSISTIVE helper flow in ../lens-search.js — WITHOUT hitting
Google. It serves a local fake results page, points the helper at it via LENS_TEST_URL,
and runs the real helper (LENS_TEST_HEADLESS=1 so the always-visible window runs headless
and CI-safe) across these scenarios, all against ONE reused window on a test port:

  A highlight + Tag  the fake page selects the binomial + clicks the injected Tag button
                     -> helper returns ONLY that name; nothing is scraped
  B Skip             the fake page clicks Skip -> cancelled contract
  C timeout          nothing tagged before a short timeout -> ok:false, no scrape
  D close            LENS_ASSIST_CLOSE shuts the reused window down cleanly

Scenarios A–C reuse the SAME window (launched on A, connected on B/C) — that IS the
window-reuse path. D closes it. Needs Node + Google Chrome + puppeteer-core (npm i here).
  node scripts/lens/test/integration.test.js     (or: just lens-test)
----------------------------------------------------------------------------*/
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const HELPER = path.join(__dirname, '..', 'lens-search.js');
const TABS_PORT = '9477'; // a dedicated port so we never touch a real assist window
const FIXTURES = path.join(__dirname, 'fixtures');
const read = f => fs.readFileSync(path.join(FIXTURES, f), 'utf8');

// --- fake Google: serve results.html, injecting per-scenario behaviour ----------------
function startServer() {
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://127.0.0.1');
    let inject = '';
    if (u.searchParams.get('tag') === '1') {
      // Simulate the human: highlight the frogfish binomial, then click the real Tag button.
      inject = "<script>setTimeout(function(){try{" +
        "var el=[].slice.call(document.querySelectorAll('body *')).find(function(n){return n.children.length===0 && /Antennarius commerson/i.test(n.textContent||'');});" +
        "if(el){var r=document.createRange();r.selectNodeContents(el);var s=window.getSelection();s.removeAllRanges();s.addRange(r);}" +
        "var b=document.getElementById('__lens_tag');if(b)b.click();" +
        "}catch(e){}},1200);</script>";
    } else if (u.searchParams.get('skip') === '1') {
      inject = "<script>setTimeout(function(){try{var b=document.getElementById('__lens_skip');if(b)b.click();}catch(e){}},1200);</script>";
    }
    let html = read('results.html');
    if (inject) html = html.replace('</body>', inject + '</body>');
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(html);
  });
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server)));
}

// --- run the real helper against a local URL, return the parsed JSON result -----------
function runHelper(testUrl, vars, killMs) {
  return new Promise(resolve => {
    const child = spawn(process.execPath, [HELPER, vars.__img || 'x'], {
      env: { ...process.env, LENS_TEST_HEADLESS: '1', LENS_TABS_PORT: TABS_PORT,
        ...(testUrl ? { LENS_TEST_URL: testUrl } : {}), ...vars },
    });
    let stdout = '';
    child.stdout.on('data', d => (stdout += d));
    const killer = setTimeout(() => { try { child.kill('SIGKILL'); } catch (_) {} }, killMs || 30000);
    child.on('close', () => {
      clearTimeout(killer);
      const line = stdout.trim().split('\n').filter(Boolean).pop() || '';
      let json = null; try { json = JSON.parse(line); } catch (_) {}
      resolve(json);
    });
  });
}

let failures = 0;
const check = (name, cond, detail) => {
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (cond || !detail ? '' : ' — ' + detail));
  if (!cond) failures++;
};

(async () => {
  const img = path.join(os.tmpdir(), 'lens-it-' + process.pid + '.jpg');
  fs.writeFileSync(img, 'not-a-real-jpeg-just-needs-to-exist'); // test mode never uploads it
  const server = await startServer();
  const base = 'http://127.0.0.1:' + server.address().port;
  try {
    console.log('A: highlight + Tag returns ONLY the selected name (no scrape)');
    {
      const r = await runHelper(base + '/results?tag=1',
        { __img: img, LENS_ASSIST_POS: 'Photo 1 of 3', LENS_INTERACTIVE_TIMEOUT: '15000' }, 25000);
      check('ok=true', !!(r && r.ok === true), JSON.stringify(r));
      check('returns the name the user highlighted', !!(r && /Antennarius commerson/i.test(r.name || '')), JSON.stringify(r));
      check('no scraped payload (no strings[]/overview)', !!(r && !r.strings && !r.overview), JSON.stringify(r));
    }

    console.log('B: Skip -> cancelled (reuses the window from A)');
    {
      const r = await runHelper(base + '/results?skip=1',
        { __img: img, LENS_ASSIST_POS: 'Photo 2 of 3', LENS_INTERACTIVE_TIMEOUT: '15000' }, 25000);
      check('ok=false', !!(r && r.ok === false), JSON.stringify(r));
      check('cancelled=true (not a hard error)', !!(r && r.cancelled), JSON.stringify(r));
    }

    console.log('C: nothing tagged before timeout -> ok=false (reuses the window)');
    {
      const r = await runHelper(base + '/results',
        { __img: img, LENS_ASSIST_POS: 'Photo 3 of 3', LENS_INTERACTIVE_TIMEOUT: '2500' }, 20000);
      check('ok=false on timeout', !!(r && r.ok === false), JSON.stringify(r));
      check('not cancelled (timed out, distinct)', !!(r && !r.cancelled), JSON.stringify(r));
    }

    console.log('D: close shuts the reused window down cleanly');
    {
      const r = await runHelper('', { __img: img, LENS_ASSIST_CLOSE: '1' }, 15000);
      check('close returns ok=true', !!(r && r.ok === true), JSON.stringify(r));
    }
  } finally {
    server.close();
    // best-effort: make sure no test window is left running
    await runHelper('', { __img: img, LENS_ASSIST_CLOSE: '1' }, 10000).catch(() => {});
    try { fs.unlinkSync(img); } catch (_) {}
  }

  console.log(failures === 0 ? '\nPASS — assistive flow green' : '\nFAIL — ' + failures + ' assertion(s) failed');
  process.exit(failures === 0 ? 0 : 1);
})();
