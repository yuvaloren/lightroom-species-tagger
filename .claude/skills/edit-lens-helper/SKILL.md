---
name: edit-lens-helper
description: Change the Go Google Lens helper (helper/) without breaking the invariants that keep it compliant, robust, and cross-platform. Use when editing the assist overlay, the window reuse / launch / close, the upload, or the Tag polling in helper/.
---

# Edit the Lens helper

The helper is a single static Go binary (`helper/`, built by `make -C helper
universal`) that opens Google Lens in the user's visible Chrome over the Chrome
DevTools Protocol and returns ONLY the species name the user highlighted.
`helper/lens/session.go` is the orchestrator; `helper/cdp/` is a deliberately
minimal hand-rolled CDP client. These invariants are load-bearing — preserve
every one.

## Invariants (don't break these)

- **Never scrape Google's results.** This is the whole compliance story. Read only
  the user's selection (via the page globals `window.__stTag` / `window.__stSkip`
  that the helper POLLS). Do NOT walk the results DOM, read the AI Overview, or
  harvest match titles.
- **Poll page globals; never install page↔helper bindings.** Polling is what lets
  a fresh helper process reconnect to the reused window across photos.
- **Never `innerHTML` or `eval` page content.** The overlay
  (`helper/lens/overlay_inject.js`, embedded via `go:embed`) builds all UI with
  `createElement` + `textContent`. Its `tagBtn.onmousedown` preventDefault is a
  shipped-bug fix — the trusted-click test guards it.
- **Respect the window lifecycle.** One DETACHED Chrome is launched on the debug
  port and *reused* (a fresh tab per photo, the others closed); each per-photo run
  disconnects (never kills) so the window survives; the run's end sends
  `LENS_ASSIST_CLOSE`, which `Browser.close`s it cleanly (no "didn't shut down
  correctly" prompt). Keep that split — the detached-lifecycle test asserts it.
- **No anti-detection.** No `--no-sandbox` on a real launch (headless test only),
  no `navigator.webdriver` spoof. The UA/Client-Hints match (golden-tested) is
  only so Google renders the normal page; the window is visible.
- **Cross-platform.** Chrome discovery, spawn (per-OS build tags in
  `helper/chrome/spawn_*.go`), and Windows version detection (directory listing,
  NEVER `chrome.exe --version` — it pops a window) must keep working. CI runs the
  integration suite on ubuntu + macos + windows.
- **Keep the binary small.** The hand-rolled CDP client exists so the shipped
  binary stays ~6 MB. Do not add `chromedp`/`cdproto` or other heavyweight deps —
  CI's size budget (8 MB per single-arch binary) will fail the build.
- **Output contract.** Exactly one line of JSON on stdout, ALWAYS exit 0:
  `{ ok:true, name }` | `{ ok:false, cancelled }` (Skip) | `{ ok:false, error }`
  (timeout/error) | `{ ok:true, closed:true }` (close). Debug goes to stderr.
  The Lua side (`src/shared/Http.lua` runHelper/interpretTagResult) parses this.

## Test the change (no network, no Google)

```bash
just helper-test    # unit suite (CDP framing, UA goldens, profile-clean, contract)
just helper-itest   # real compiled helper vs a local fake Google: ten scenarios,
                    # the upload path, detached lifecycle, trusted click
```

Both run with the race detector. CI repeats `helper-itest` on all three OSes.

## Live verification (network; before releases)

```bash
just lens-live      # REAL Google, headed Chrome, ~30 s: uploads a generated JPEG,
                    # stands in for the human's Tag press over the debug port
```

Run it on the Mac and the Windows VM. Residential network — Google challenges
datacenter/VPN IPs. After a helper change, also verify once inside Lightroom.
To inspect a real run: `LENS_DEBUG=1 helper/dist/<os>/<arch>/lens-helper photo.jpg`.

## Scope

Keep it a helper, not a framework: a small auditable Go module behind the `Http`
seam. Precision is GBIF's job downstream; this just hands back the string the
user picked.
