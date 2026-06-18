# Google Lens browser helper

Google Lens has **no anonymous API**, and its results page is rendered by
**JavaScript** — so a plain HTTP client (curl, or Lightroom's `LrHttp`) only ever
gets the "enable JavaScript" shell, never the matches. The only way to read the
results without a paid scraper API is to run a **real browser**.

`lens-search.js` does exactly that:

1. uploads the image over `curl` to `lens.google.com/v3/upload` (yields a results
   URL + a fresh **anonymous** session — no login, no cookies to paste),
2. transplants that session (incl. `HttpOnly` cookies) into your **installed
   Google Chrome** via `puppeteer-core` (a **visible** window — Google's real page
   is shown, not scraped invisibly),
3. navigates Chrome to the results URL so Chrome runs the JS, then scrapes the
   visible match strings,
4. prints `{ "ok": true, "strings": [ … ] }` on stdout.

Those strings feed the plugin's `SpeciesParser → GBIF → scorer` pipeline (which
gates precision), so the helper stays recall-oriented and tolerant of noise.

## Setup

```
cd scripts/lens
npm i              # installs puppeteer-core (uses your installed Chrome; no download)
```

Requirements: **Node.js**, **Google Chrome** installed, and `curl`. macOS/Linux
(POSIX shell quoting). Override Chrome with `LENS_CHROME=/path/to/chrome`.

## Use

```
node lens-search.js /path/to/photo.jpg
```

- The Lightroom plugin shells out to the **bundled** copy (`build/build.lua` copies
  this folder, incl. `node_modules`, into the `.lrplugin`). Set the **node path**
  in plugin settings if `node` isn't auto-found.
- `scripts/live-accuracy.lua` (`just live-accuracy`) uses it to measure real
  accuracy against the ground-truth set.

## Caveats

- **Run from a residential connection.** Google blocks automated access from
  datacenter / VPN / shared IPs (you'll get no usable results).
- Best-effort and unofficial: Google can change the page or rate-limit; on failure
  the helper prints `{ "ok": false, … }` and the photo falls through to *needs
  review*. It is automated access to a consumer Google surface — use it for your
  own low-volume tagging.
