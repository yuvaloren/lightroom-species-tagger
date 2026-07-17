/*----------------------------------------------------------------------------
src/helper/lens/overlay_inject.js
The assistive control bar injected into the Google Lens page: a bar docked at the
BOTTOM (so it never covers Google's own top bar) with an "m of n" counter and the Tag
+ Skip buttons. YOU read Google's real results; pressing Tag records ONLY
window.getSelection() — the species name you highlighted. Nothing on the page is
scraped, and there is no keyword box of ours (use Google's own search box to refine).

Handed to page.evaluateOnNewDocument(assistOverlayInjector, pos), so it is serialised
and runs in the browser on every document. It communicates by setting page globals
(window.__stTag / window.__stSkip) that the Node side POLLS — no exposeFunction, so it
keeps working when the helper reconnects to a reused window/tab across photos. Builds
all UI with createElement + textContent (never innerHTML). Top frame only: the same
guard as before keeps it out of a same-origin reCAPTCHA iframe.
----------------------------------------------------------------------------*/
function assistOverlayInjector(pos) {
  if (window.top !== window.self) return;
  var add = function () {
    if (!document.body || document.getElementById('__lens_assist')) return;
    var bar = document.createElement('div');
    bar.id = '__lens_assist';
    bar.style.cssText = 'position:fixed;bottom:0;left:0;right:0;z-index:2147483647;background:#1b4535;color:#eef3ee;font:13px system-ui,-apple-system,sans-serif;padding:10px 16px;display:flex;gap:12px;align-items:center;flex-wrap:wrap;border-top:2px solid #e6a23c;box-shadow:0 -4px 14px rgba(0,0,0,.3)';

    var brand = document.createElement('strong');
    brand.textContent = '🪶 Species Tagger';
    brand.style.cssText = 'white-space:nowrap';
    bar.appendChild(brand);

    if (pos) {
      var counter = document.createElement('span');
      counter.textContent = pos;                       // e.g. "Photo 2 of 5"
      counter.style.cssText = 'color:#cfe0d4;white-space:nowrap;background:rgba(255,255,255,.09);padding:3px 10px;border-radius:999px';
      bar.appendChild(counter);
    }

    var spacer = document.createElement('span');
    spacer.style.cssText = 'flex:1';
    bar.appendChild(spacer);

    var hint = document.createElement('span');
    hint.textContent = 'Highlight the species Latin name and press';
    hint.style.cssText = 'color:#a8c4b4;white-space:nowrap';
    bar.appendChild(hint);

    var tagBtn = document.createElement('button');
    tagBtn.id = '__lens_tag';
    tagBtn.textContent = '🏷️ Tag';
    tagBtn.style.cssText = 'background:#e6a23c;color:#1d1405;border:0;border-radius:999px;padding:8px 18px;font-weight:700;cursor:pointer;font:inherit;transition:background .12s,color .12s';
    // A real mouse press on a <button> takes focus and COLLAPSES the page's text
    // selection before the click handler runs — so window.getSelection() would already
    // be empty by the time Tag reads it, and the user's highlight would be lost. Stop the
    // mousedown default so the button never steals focus (the standard toolbar-button
    // technique), preserving the selection for onclick. A programmatic .click() (the test
    // harness) skips mousedown, which is why this gap only shows up under a real click.
    tagBtn.onmousedown = function ( e ) { e.preventDefault(); };
    tagBtn.onclick = function () {
      if (tagBtn.disabled) return;
      var sel = (window.getSelection ? String(window.getSelection()) : '').replace(/^\s+|\s+$/g, '');
      if (!sel) {
        // nothing highlighted yet — nudge instead of doing nothing silently
        tagBtn.textContent = 'Highlight a name first';
        setTimeout(function () { if (!tagBtn.disabled) tagBtn.textContent = '🏷️ Tag'; }, 1500);
        return;
      }
      // Instant feedback the moment you press: the tag is registered and the plugin is
      // resolving it + moving on (Node polls window.__stTag, which can take a beat).
      tagBtn.textContent = '⏳ Tagging…';
      tagBtn.style.background = '#2f7d55';   // amber "ready" -> green "working"
      tagBtn.style.color = '#eafff2';
      tagBtn.style.cursor = 'default';
      tagBtn.disabled = true;
      window.__stTag = sel;
    };
    bar.appendChild(tagBtn);

    var skipBtn = document.createElement('button');
    skipBtn.id = '__lens_skip';
    skipBtn.textContent = 'Skip';
    skipBtn.style.cssText = 'background:transparent;color:#a8c4b4;border:1px solid rgba(255,255,255,.22);border-radius:999px;padding:7px 12px;cursor:pointer;font:inherit';
    skipBtn.onclick = function () { window.__stSkip = true; };
    bar.appendChild(skipBtn);

    document.body.appendChild(bar);
  };
  if (document.body) add();
  else {
    document.addEventListener('DOMContentLoaded', add);
    document.addEventListener('readystatechange', function () { if (document.readyState !== 'loading') add(); });
  }
}

module.exports = { assistOverlayInjector };
