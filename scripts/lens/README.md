# Google Lens browser helper (assistive)

Google Lens has **no anonymous API** and renders its results with **JavaScript**, so it
can't be read by a plain HTTP client. This helper opens Lens in the user's **real,
visible Chrome** and lets the *user* pick the species — the plugin never scrapes the page.

`lens-search.js` does exactly that:

1. uploads the image over `curl` to `lens.google.com/v3/upload` the way the Lens website
   does (yields a results URL + a fresh **anonymous**, no-login session),
2. opens that session in your **installed Google Chrome** via `puppeteer-core` — a
   **visible** window showing Google's real results — reusing ONE window across photos (a
   fresh tab each), and injects a small bottom bar with a **Tag** / **Skip** button and a
   "Photo m of n" counter,
3. when you highlight a species name and press **Tag**, it reads **only**
   `window.getSelection()` (via a page global it polls — never the results DOM) and
   prints `{ "ok": true, "name": "…" }` on stdout.

That single name feeds the plugin's `SelectedName → GBIF` resolver, which turns it into
canonical common + Latin keywords. Because nothing is scraped and you initiate the reading,
this stays within Google's terms.

## Setup

```
cd scripts/lens
npm i              # installs puppeteer-core (uses your installed Chrome; no download)
```

Requirements: **Node.js**, **Google Chrome** installed, and `curl`. Chrome and Node are
found automatically on macOS / Windows / Linux; override Chrome with
`LENS_CHROME=/path/to/chrome`.

## Use

```
node lens-search.js /path/to/photo.jpg      # LENS_ASSIST_POS="Photo 2 of 5" shows the counter
node lens-search.js x                        # with LENS_ASSIST_CLOSE=1: close the reused window
```

The Lightroom plugin shells out to the **bundled** copy (`build/build.lua` copies this
folder, incl. `node_modules`, into the `.lrplugin`). Output is one JSON line:
`{ ok:true, name }` | `{ ok:false, cancelled }` (Skip) | `{ ok:false, error }` (timeout).

## Test

```
npm test           # drives the real helper against a local fake Google (no network)
```

## Caveats

- **Run from a residential connection.** Google challenges automated access from
  datacenter / VPN / shared IPs; if an "are you human" check appears, solve it yourself in
  the visible window, then highlight and Tag.
- Best-effort: Google can change or rate-limit the page. On any failure the helper prints
  `{ "ok": false, … }` and the photo is left untagged.
