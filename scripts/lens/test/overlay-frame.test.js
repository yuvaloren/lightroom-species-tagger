#!/usr/bin/env node
/*----------------------------------------------------------------------------
scripts/lens/test/overlay-frame.test.js
Regression test for the interactive control-bar injection (../overlay-inject.js).

Bug it guards against: the bar is injected via page.evaluateOnNewDocument(), which
runs in EVERY frame. Google's reCAPTCHA image challenge ("select all squares with…")
is a same-origin google.com iframe, so without a top-frame guard the bar was added
INSIDE the challenge popup too — a second, unwanted "Parse results" header clipping
the captcha. The fix: overlayInjector() returns early unless window.top===window.self.

This injects the REAL overlayInjector into a page that embeds a same-origin iframe
(standing in for the challenge frame) and asserts the bar lands once on the top page
and never in the iframe. Needs Node + Google Chrome + puppeteer-core (npm i here).
  node scripts/lens/test/overlay-frame.test.js     (or: just lens-test)
----------------------------------------------------------------------------*/
const http = require('http');
const puppeteer = require('puppeteer-core');
const { overlayInjector } = require('../overlay-inject');

const CHROME = process.env.LENS_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// A page embedding a same-origin iframe whose content sits at the very top — a
// stand-in for the reCAPTCHA challenge frame, where a stray bar would clip the grid.
const CHILD = '<!doctype html><html><body style="margin:0">' +
  '<div style="position:fixed;top:0;left:0;width:300px;height:300px;background:#eee">captcha grid</div>' +
  '</body></html>';
const PARENT = '<!doctype html><html><body><h1>unusual traffic</h1>' +
  '<iframe src="/child" style="width:320px;height:320px"></iframe></body></html>';

let failures = 0;
const check = (name, cond, detail) => {
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (cond || !detail ? '' : ' — ' + detail));
  if (!cond) failures++;
};

(async () => {
  const server = await new Promise(r => {
    const s = http.createServer((req, res) => {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      res.end(req.url.startsWith('/child') ? CHILD : PARENT);
    });
    s.listen(0, '127.0.0.1', () => r(s));
  });
  const origin = 'http://127.0.0.1:' + server.address().port;
  let browser;
  try {
    browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new', args: ['--no-sandbox'] });
    const page = await browser.newPage();
    // Bind the handlers the bar's buttons reference, exactly as installInteractive does.
    await page.exposeFunction('__lensParse', () => {});
    await page.exposeFunction('__lensCancel', () => {});
    await page.evaluateOnNewDocument(overlayInjector);            // the REAL injector, all frames
    await page.goto(origin + '/', { waitUntil: 'networkidle2', timeout: 30000 });
    await new Promise(r => setTimeout(r, 500));

    const topBars = await page.evaluate(() => document.querySelectorAll('#__lens_overlay').length);
    const iframe = page.frames().find(f => f !== page.mainFrame());
    const frameBars = iframe ? await iframe.evaluate(() => document.querySelectorAll('#__lens_overlay').length) : -1;
    const hasButtons = await page.evaluate(() => {
      const bar = document.getElementById('__lens_overlay');
      return !!bar && /Parse results/.test(bar.textContent) && /Cancel/.test(bar.textContent);
    });

    console.log('overlay injection across frames:');
    check('exactly one control bar on the top page', topBars === 1, 'got ' + topBars);
    check('the iframe (challenge frame) got a frame to test', !!iframe, 'no subframe found — test is not exercising the path');
    check('NO control bar inside the iframe (the bug)', frameBars === 0, 'got ' + frameBars + ' bar(s) in the iframe');
    check('the top bar still has Parse results + Cancel', hasButtons);
  } catch (e) {
    check('test ran without throwing', false, e.message);
  } finally {
    if (browser) await browser.close().catch(() => {});
    server.close();
  }

  console.log(failures === 0 ? '\nPASS — overlay injects on the top page only' : '\nFAIL — ' + failures + ' assertion(s) failed');
  process.exit(failures === 0 ? 0 : 1);
})();
