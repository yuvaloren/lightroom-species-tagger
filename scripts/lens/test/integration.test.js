#!/usr/bin/env node
/*----------------------------------------------------------------------------
scripts/lens/test/integration.test.js
Automated integration test for the interactive challenge-handling flow in
../lens-search.js — WITHOUT hitting Google. It serves a local fake "challenge"
page and a fake "results" page, points the helper at them via LENS_TEST_URL, and
runs the real helper (headless, LENS_TEST_HEADLESS=1 so the "visible" escalation
window is headless and CI-safe) across these scenarios:

  A confident       /results            -> parses in pass 1, no escalation
  B challenge+auto   /challenge?solve=auto -> detect challenge, escalate, the page
                                            "solves" itself, auto-detect parses
  C challenge+cancel /challenge?solve=never + short timeout -> escalate, time out,
                                            return the cancelled contract
  D non-interactive  /challenge (no LENS_INTERACTIVE) -> best-effort scrape, returns
  E parse button     /results-weak?clickParse=1 -> low-signal, escalate, the page
                                            invokes window.__lensParse() (simulating a
                                            click of the injected "Parse results" button)

Needs Node + Google Chrome + puppeteer-core (npm i in scripts/lens). Run:
  node scripts/lens/test/integration.test.js     (or: just lens-test)

To raise fidelity, drop a REAL captured page into fixtures/ (the debug mode writes
page.html + page-challenge.html — see ../README / debug-lens.sh) and the server will
serve it; adjust the assertions to match its content.
----------------------------------------------------------------------------*/
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const HELPER = path.join(__dirname, '..', 'lens-search.js');
const FIXTURES = path.join(__dirname, 'fixtures');
const read = f => fs.readFileSync(path.join(FIXTURES, f), 'utf8');

// --- fake Google: serve the fixtures, injecting per-scenario behaviour ----------
function startServer() {
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://127.0.0.1');
    let file, inject = '';
    if (u.pathname === '/results') file = 'results.html';
    else if (u.pathname === '/results-weak') {
      file = 'results-weak.html';
      if (u.searchParams.get('clickParse') === '1') {
        // simulate the user clicking the injected "Parse results" button
        inject = "<script>setTimeout(function(){try{window.__lensParse&&window.__lensParse();}catch(e){}},1500);</script>";
      }
    } else if (u.pathname === '/challenge') {
      file = 'challenge.html';
      const s = u.searchParams.get('solve');
      if (s === 'auto') inject = "<script>setTimeout(function(){location.href='/results?vsrid=test';},1200);</script>";
      else if (s === 'button') inject = "<script>document.getElementById('solve').onclick=function(){location.href='/results?vsrid=test';};</script>";
    } else { res.writeHead(404); res.end('not found'); return; }
    let html = read(file);
    if (inject) html = html.replace('</body>', inject + '</body>');
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(html);
  });
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server)));
}

// --- run the real helper against a local URL, return the parsed JSON result -----
function runHelper(testUrl, env, killMs) {
  return new Promise(resolve => {
    const child = spawn(process.execPath, [HELPER, env.__img], {
      env: { ...process.env, LENS_TEST_URL: testUrl, LENS_TEST_HEADLESS: '1', ...env.vars },
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', d => (stdout += d));
    child.stderr.on('data', d => (stderr += d));
    const killer = setTimeout(() => { try { child.kill('SIGKILL'); } catch (_) {} }, killMs || 40000);
    child.on('close', () => {
      clearTimeout(killer);
      const line = stdout.trim().split('\n').filter(Boolean).pop() || '';
      let json = null; try { json = JSON.parse(line); } catch (_) {}
      resolve({ json, stdout, stderr });
    });
  });
}

// --- tiny assertion harness ------------------------------------------------------
let failures = 0;
const check = (name, cond, detail) => {
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (cond || !detail ? '' : ' — ' + detail));
  if (!cond) failures++;
};
const has = (r, re) => !!(r && r.strings && r.strings.some(s => re.test(s)));

(async () => {
  const img = path.join(os.tmpdir(), 'lens-it-' + process.pid + '.jpg');
  fs.writeFileSync(img, 'not-a-real-jpeg-just-needs-to-exist'); // test mode never uploads it
  const server = await startServer();
  const base = 'http://127.0.0.1:' + server.address().port;
  const I = { vars: { LENS_INTERACTIVE: '1' }, __img: img };
  try {
    console.log('A: confident results parse in pass 1 (no escalation)');
    {
      const { json: r } = await runHelper(base + '/results?vsrid=test', { ...I, vars: { LENS_INTERACTIVE: '1', LENS_INTERACTIVE_TIMEOUT: '20000' } }, 30000);
      check('ok=true', r && r.ok === true, JSON.stringify(r));
      check('found the frogfish binomial', has(r, /Antennarius commerson/i));
      check('AI Overview captured', !!(r && r.overview && /Antennarius commerson/i.test(r.overview)));
      check('weasel (Related searches noise) excluded', !has(r, /Mustela subpalmata/i));
    }

    console.log('B: challenge detected -> escalate -> auto-solve -> auto-detect parses');
    {
      // pass-1 breaks on the challenge and only ever sees /challenge, so parsing the
      // /results content here is itself proof the escalation + auto-detect ran.
      const { json: r } = await runHelper(base + '/challenge?solve=auto', { ...I, vars: { LENS_INTERACTIVE: '1', LENS_INTERACTIVE_TIMEOUT: '25000' } }, 40000);
      check('ok=true after solving', r && r.ok === true, JSON.stringify(r));
      check('parsed the real results (only reachable via escalation)', has(r, /Antennarius commerson/i));
      check('weasel still excluded', !has(r, /Mustela subpalmata/i));
    }

    console.log('C: challenge never solved -> timeout -> cancelled');
    {
      const { json: r } = await runHelper(base + '/challenge?solve=never', { ...I, vars: { LENS_INTERACTIVE: '1', LENS_INTERACTIVE_TIMEOUT: '4000' } }, 30000);
      check('ok=false', r && r.ok === false, JSON.stringify(r));
      check('cancelled=true (not a hard error)', !!(r && r.cancelled));
    }

    console.log('D: non-interactive challenge -> reports challenged, does NOT scrape it as results');
    {
      const { json: r } = await runHelper(base + '/challenge?solve=never', { __img: img, vars: {} }, 30000);
      check('returns a JSON result', !!r, 'no JSON on stdout');
      check('ok=false (a challenge is not a success)', !!(r && r.ok === false), JSON.stringify(r));
      check('challenged=true (distinct backoff signal for the caller)', !!(r && r.challenged));
      check('does not surface the frogfish or challenge boilerplate as results',
        !has(r, /Antennarius commerson/i) && !!(r && (!r.strings || r.strings.length === 0)));
    }

    console.log('E: low-signal page -> escalate -> "Parse results" button parses');
    {
      const { json: r } = await runHelper(base + '/results-weak?clickParse=1', { ...I, vars: { LENS_INTERACTIVE: '1', LENS_INTERACTIVE_TIMEOUT: '20000' } }, 40000);
      check('ok=true via the Parse button', r && r.ok === true, JSON.stringify(r));
      check('parsed the page content', has(r, /Antennarius commerson/i));
    }
  } finally {
    server.close();
    try { fs.unlinkSync(img); } catch (_) {}
  }

  console.log(failures === 0 ? '\nPASS — all scenarios green' : '\nFAIL — ' + failures + ' assertion(s) failed');
  process.exit(failures === 0 ? 0 : 1);
})();
