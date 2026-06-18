/*----------------------------------------------------------------------------
scripts/lens/overlay-inject.js
The interactive control bar ("complete any Google check, then click Parse results")
injected into the page during the challenge-handling flow, factored out of
lens-search.js so it can be unit-tested directly (test/overlay-frame.test.js).

This function is handed to page.evaluateOnNewDocument(), so puppeteer serialises it
and runs it in the browser on EVERY frame. It must therefore be self-contained —
reference only browser globals (window, document) and the exposed handlers BY NAME
(window.__lensParse / window.__lensCancel), never via a Node closure.
----------------------------------------------------------------------------*/
function overlayInjector() {
  // Only inject into the TOP frame. evaluateOnNewDocument runs in every frame, and
  // Google's reCAPTCHA image challenge is a same-origin google.com iframe — without
  // this guard the bar is added inside the challenge popup too (a second, unwanted
  // header that clips the captcha). The control belongs only on the page.
  if (window.top !== window.self) return;
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
}

module.exports = { overlayInjector };
