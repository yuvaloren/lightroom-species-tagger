---
name: edit-lens-helper
description: Change the Node/Puppeteer Google Lens helper (scripts/lens) without breaking the invariants that keep it compliant, robust, and cross-platform. Use when editing the assist overlay, the window reuse / launch / close, the upload, or the Tag polling in scripts/lens/.
---

# Edit the Lens helper

`scripts/lens/lens-search.js` opens Google Lens in the user's visible Chrome and returns
ONLY the species name the user highlighted. Its header comment is the spec; read it first.
These invariants are load-bearing — preserve every one.

## Invariants (don't break these)

- **Never scrape Google's results.** This is the whole compliance story. Read only
  `window.getSelection()` (via the page globals `window.__stTag` / `window.__stSkip` that
  Node polls). Do NOT walk the results DOM, read the AI Overview, or harvest match titles.
- **No exposeFunction for the Tag/Skip signal.** Use the polled page globals — that's what
  lets the helper reconnect to the reused window across photos. Adding `exposeFunction`
  back would break on the second photo (the binding persists but points at a dead process).
- **Never `innerHTML` or `eval` page content.** Build the overlay with `createElement` +
  `textContent` only (see `overlay-inject.js`).
- **Respect the window lifecycle.** One detached window is launched on the debug port and
  *reused* (a fresh tab per photo, the others closed); each per-photo run `disconnect`s
  (never kills) so the window survives; the run's end sends `LENS_ASSIST_CLOSE` which
  `browser.close()`s it cleanly (no "didn't shut down correctly" prompt). Keep that split.
- **No anti-detection.** No `--no-sandbox` on a real launch (headless test only), no
  `navigator.webdriver` spoof. The UA/Client-Hints match is only so Google renders the
  normal page; the window is visible.
- **Cross-platform.** Chrome discovery (`findChrome`) and the shell-free `curl`/`spawn`
  calls must keep working on macOS / Windows / Linux.
- **Output contract.** Exactly one line of JSON on stdout: `{ ok:true, name }` |
  `{ ok:false, cancelled }` (Skip) | `{ ok:false, error }` (timeout/error) |
  `{ ok:true, closed:true }` (the close command). Debug goes to stderr.

## Test the change (no network, no Google)

```bash
cd scripts/lens && npm ci && npm test      # drives the real helper against a fake Google
```

Or `just lens-test`. It exercises the whole assist round-trip headlessly — highlight + Tag
→ name, Skip → cancelled, timeout, window reuse across scenarios, and clean close.

## What can't be tested here

The real Google DOM, the upload against live Google, and the Lightroom keyword write can't
be exercised offline. After a helper change, verify once in Lightroom on a residential
network. To inspect a real run, `LENS_DEBUG=1 node lens-search.js photo.jpg`.

## Scope

Keep it a helper, not a framework: one auditable file behind the `Http` seam. Precision is
GBIF's job downstream; this just hands back the string the user picked.
