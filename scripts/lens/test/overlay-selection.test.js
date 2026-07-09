#!/usr/bin/env node
/*----------------------------------------------------------------------------
scripts/lens/test/overlay-selection.test.js
Regression test for the one thing the integration harness structurally can't catch:
a REAL mouse press on the Tag button.

The integration test drives Tag with a programmatic `button.click()`, which fires only a
click event — no mousedown, so focus never moves and the page's text selection survives.
A human clicks with a real mouse: the mousedown moves focus to the <button> and COLLAPSES
the selection before onclick runs, so window.getSelection() is already empty when Tag reads
it. That gap shipped a helper that looked green in CI but dropped every real highlight
("Highlight a name first"). The fix is `tagBtn.onmousedown = e => e.preventDefault()`.

This test injects the real overlay, selects text, and clicks Tag with puppeteer's
page.mouse (CDP-dispatched, i.e. TRUSTED events that perform native focus/selection
defaults). It asserts:
  1. mechanism — the Tag button cancels its mousedown default (so it can't steal focus);
  2. functional — after a trusted click on Tag, window.__stTag holds the selection.

Headless is the only headless path (test-only, per edit-lens-helper). Needs Chrome +
puppeteer-core (npm i here).  node scripts/lens/test/overlay-selection.test.js
----------------------------------------------------------------------------*/
const puppeteer = require('puppeteer-core');
const { findChrome } = require('../find-chrome');
const { assistOverlayInjector } = require('../overlay-inject');

const NAME = 'Conolophus pallidus';
const PAGE = '<!doctype html><meta charset="utf-8"><body>' +
  '<h2 id="sp">' + NAME + '</h2><p>some other, unrelated body text</p></body>';

let failures = 0;
const check = (name, cond, detail) => {
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (cond || !detail ? '' : ' — ' + detail));
  if (!cond) failures++;
};

(async () => {
  const browser = await puppeteer.launch({
    executablePath: findChrome(),
    headless: 'new',
    args: ['--no-sandbox', '--disable-setuid-sandbox'], // headless test only (see skill)
  });
  try {
    const page = await browser.newPage();
    await page.setContent(PAGE, { waitUntil: 'domcontentloaded' });
    await page.evaluate(assistOverlayInjector, null); // inject the real bar, no counter

    console.log('mechanism: the Tag button cancels its mousedown default (never steals focus)');
    {
      const prevented = await page.evaluate(() => {
        const b = document.getElementById('__lens_tag');
        // dispatchEvent returns false iff a handler called preventDefault on a cancelable event
        return !b.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
      });
      check('mousedown default is prevented', prevented === true, 'defaultPrevented=' + prevented);
    }

    console.log('functional: select the name, then a REAL (trusted) click on Tag records it');
    {
      // Highlight the species name exactly as a user would.
      const selected = await page.evaluate(() => {
        const el = document.getElementById('sp');
        const r = document.createRange();
        r.selectNodeContents(el);
        const s = window.getSelection();
        s.removeAllRanges();
        s.addRange(r);
        return String(window.getSelection());
      });
      check('the name is selected before clicking', selected === NAME, JSON.stringify(selected));

      // Click Tag through the CDP mouse: a trusted mousedown that, WITHOUT the fix, would
      // collapse the selection before onclick reads it.
      const box = await (await page.$('#__lens_tag')).boundingBox();
      await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);

      const tag = await page.evaluate(() => window.__stTag || null);
      check('window.__stTag holds the selection after a real click', tag === NAME, JSON.stringify(tag));
    }
  } finally {
    await browser.close();
  }
  console.log(failures === 0 ? '\nPASS — real-click selection preserved' : '\nFAIL — ' + failures + ' assertion(s) failed');
  process.exit(failures === 0 ? 0 : 1);
})();
