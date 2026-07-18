/*----------------------------------------------------------------------------
src/helper/lens/overlay_inject.js
The assistive control bar injected into the Google Lens page: a bar docked at the
BOTTOM (so it never covers Google's own top bar) with an "m of n" counter and the Tag
+ Skip buttons. YOU read Google's real results; pressing Tag records ONLY
window.getSelection() — the species name you highlighted. Nothing on the page is
scraped, and there is no keyword box of ours (use Google's own search box to refine).

Handed to page.evaluateOnNewDocument(assistOverlayInjector, pos, token), so it is
serialised and runs in the browser on every document. It communicates by setting page
globals (window.__stTag / window.__stSkip) that the Go side POLLS — no exposeFunction,
so it keeps working when the helper reconnects to a reused window/tab across photos.

Anti-hijack: the assist window's debug port is a fixed, predictable localhost port,
so ANY local process could connect and blind-write window.__stTag to forge a Tag
(observed in the wild: a stand-in process injecting a fixed species name). So the
button does not write a bare name — it writes `<token>|<name>`, where `token` is a
per-photo nonce the helper injected via addScriptToEvaluateOnNewDocument. The helper
accepts a Tag only when the token matches the CURRENT photo's nonce; a blind or stale
write (no token, wrong token) is ignored and the wait continues. Skip is tokened the
same way. Builds all UI with createElement + textContent (never innerHTML). Top frame
only: the same guard keeps it out of a same-origin reCAPTCHA iframe.
----------------------------------------------------------------------------*/
function assistOverlayInjector(pos, token) {
  if (window.top !== window.self) return;
  token = token || '';

  // ── selection snapping ──────────────────────────────────────────────────────
  // Highlighting a name by hand is fiddly: it's easy to catch a parenthesis or
  // miss the first/last letters. The moment the mouse is released we clean the
  // live selection IN PLACE — so the user sees the corrected highlight before
  // pressing Tag: characters that can't be part of a name (parentheses, quotes,
  // commas, whitespace) are dropped from the edges, then a partially selected
  // word is completed to its boundaries. Interior text is never touched, and a
  // selection with nothing name-like in it is left alone. Tag also snaps once,
  // synchronously, so a keyboard-made selection gets the same treatment.
  // NAMECH: what a species name is made of — letters in any script (Chrome's
  // regexes know Unicode property classes), combining marks, digits, and the
  // hyphens/apostrophes of common names ("Blue-footed", "Randall’s").
  var NAMECH = /[\p{L}\p{M}\p{N}'’-]/u;
  var snapSelection = function () {
    var s = window.getSelection ? window.getSelection() : null;
    if (!s || s.rangeCount !== 1 || s.isCollapsed) return;
    var r = s.getRangeAt(0);
    var sc = r.startContainer, ec = r.endContainer;
    // Drag selections start and end in text nodes; anything else (triple-click
    // block selections land on elements) is deliberate — leave it alone.
    if (sc.nodeType !== Node.TEXT_NODE || ec.nodeType !== Node.TEXT_NODE) return;
    var so = r.startOffset, eo = r.endOffset;
    // 1. shrink: drop non-name characters at the edges (each edge stays within
    //    its own text node — the 99% case for a drag over words).
    while (so < sc.data.length && !NAMECH.test(sc.data.charAt(so)) && !(sc === ec && so >= eo)) so++;
    while (eo > 0 && !NAMECH.test(ec.data.charAt(eo - 1)) && !(sc === ec && eo <= so)) eo--;
    if (sc === ec && so >= eo) return; // nothing name-like inside: not ours to fix
    // 2. grow: complete a partially selected word at either end.
    while (so > 0 && NAMECH.test(sc.data.charAt(so - 1))) so--;
    while (eo < ec.data.length && NAMECH.test(ec.data.charAt(eo))) eo++;
    if (so === r.startOffset && eo === r.endOffset) return; // already clean
    var nr = document.createRange();
    nr.setStart(sc, so);
    nr.setEnd(ec, eo);
    s.removeAllRanges();
    s.addRange(nr);
  };
  // One listener per document, no matter how often the SPA-wipe watchdog
  // re-runs this injector (listeners on `document` survive a body wipe). The
  // deferral lets the browser finish building the selection for every gesture
  // (drag, double-click, shift-click) before we look at it.
  if (!window.__stSnapWired) {
    window.__stSnapWired = 1;
    document.addEventListener('mouseup', function () { setTimeout(snapSelection, 0); });
  }

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
      snapSelection(); // same cleanup for selections the mouseup path didn't see (keyboard)
      var sel = (window.getSelection ? String(window.getSelection()) : '').replace(/^\s+|\s+$/g, '');
      if (!sel) {
        // nothing highlighted yet — nudge instead of doing nothing silently
        tagBtn.textContent = 'Highlight a name first';
        setTimeout(function () { if (!tagBtn.disabled) tagBtn.textContent = '🏷️ Tag'; }, 1500);
        return;
      }
      // Instant feedback the moment you press: the tag is registered and the plugin is
      // resolving it + moving on (the Go side polls window.__stTag, which can take a beat).
      tagBtn.textContent = '⏳ Tagging…';
      tagBtn.style.background = '#2f7d55';   // amber "ready" -> green "working"
      tagBtn.style.color = '#eafff2';
      tagBtn.style.cursor = 'default';
      tagBtn.disabled = true;
      // token-prefixed so a blind write to __stTag from another process is ignored.
      window.__stTag = token + '|' + sel;
    };
    bar.appendChild(tagBtn);

    var skipBtn = document.createElement('button');
    skipBtn.id = '__lens_skip';
    skipBtn.textContent = 'Skip';
    skipBtn.style.cssText = 'background:transparent;color:#a8c4b4;border:1px solid rgba(255,255,255,.22);border-radius:999px;padding:7px 12px;cursor:pointer;font:inherit';
    skipBtn.onclick = function () { window.__stSkip = token; };
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
