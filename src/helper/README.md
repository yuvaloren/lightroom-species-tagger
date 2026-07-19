# helper/ — the Go lens helper

The single native binary the plugin bundles: it opens Google Lens in the
user's **visible** Chrome over the Chrome DevTools Protocol and returns only
the text the user highlighted. It replaced the bundled Node.js + puppeteer-core
runtime in v0.4.0 (~230 MB per mac install → ~6 MB per binary). `main.go` has
three modes: the **assist** flow (default — blocks on the user's Tag/Skip),
**`LENS_HASH=1`** (dHash every image listed in `LENS_HASH_LIST` for burst
detection; local only — no Chrome), and **`enable-installed`** (installer
hook: clear Lightroom's remembered "disabled" state for the plug-in copy at a
path; human-readable output, not JSON).

- `cdp/` — a minimal hand-rolled CDP client: WebSocket transport
  (`coder/websocket`, the one dependency), request/response mux, flatten-mode
  sessions, 14 typed method wrappers. Deliberately NOT `chromedp` — the tiny
  method surface is why the binary stays small (CI enforces an 8 MB budget).
- `chrome/` — locate the installed Chrome, spawn it DETACHED (per-OS build
  tags), read its version (on Windows: directory listing, never
  `chrome.exe --version`), and mark the assist profile clean before launches.
- `lens/` — the session orchestrator (`session.go`), the embedded overlay
  (`overlay_inject.js`), UA/Client-Hints construction, and the test suites.
- `imghash/` — perceptual fingerprinting of rendered previews, used for burst
  detection. Pixels-only: it imports neither Chrome nor CDP.
- `lrprefs/` — Lightroom prefs editing, used by the installers'
  enable-on-install hook (the `enable-installed` mode).
- `cmd/presstag/` — debug-port test driver: stands in for the human's Tag/Skip
  press over the assist window's debug port. Test tooling, never shipped.
- `main.go` — argv/env in, ONE line of JSON out, always exit 0. The contract
  the Lua side (`src/plugin/shared/Http.lua`) parses.

## Build

```bash
just build   # cross-compiles all four per-arch binaries plus the lipo'd
             # universal mac binary into src/helper/dist/
```

## Test

```bash
just test           # unit: CDP framing, UA goldens, profile-clean, output
                    # contract (or: cd src/helper && go test -race ./...)
just helper-itest   # integration: the real binary vs a local fake Google — ten
                    # scenarios, the upload path, detached lifecycle, trusted click
just lens-live      # opt-in, NEVER CI: real Google, headed Chrome, ~30 s
```

Editing this code? Read the invariants in the header of `lens/session.go` first — the
invariants there (no scraping, polled globals, window lifecycle, size budget)
are load-bearing.
