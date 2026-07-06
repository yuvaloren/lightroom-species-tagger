# Privacy & data flow

This plugin sends image data to a third-party service to recognise subjects. Here
is exactly what leaves your machine, and when.

## What is sent

Before anything is sent, the photo is rendered to a **downsized JPEG**
(longest edge ≈ 1024 px by default). Because it's a fresh render, the original
**EXIF/GPS metadata is not included** in what's sent. No third-party image host
is involved — the bytes go straight to Google Lens.

### Google Lens
- The downsized JPEG **bytes** are uploaded to `lens.google.com` (the same
  endpoint the Lens website uses). Because Lens has no anonymous API and renders
  results with JavaScript, the plugin drives your **installed Google Chrome** (in a
  **visible window**, via the bundled Node helper, so Google's real page is shown
  rather than scraped invisibly) to run the search and read the results.
- An **anonymous** Google session is used (no account, no login, no cookie to
  paste). To look like a returning user rather than a fresh bot each time, the
  helper keeps a **local Chrome profile + cookie jar** under
  `~/.cache/speciestagger-lens` (or the OS-appropriate cache directory) and reuses
  it across runs — these cookies stay on your machine and are sent only to Google;
  delete that folder to reset. No API key and no third-party host are involved.
  This is automated access to a consumer Google surface, so Google may rate-limit
  or block it (run it from a normal home connection); nothing is sent anywhere else.
- If you provide **extra keywords** for a run, or the photo has a **location**
  (GPS/IPTC), that text is added to the Lens search and therefore sent to Google
  as part of the query. The location is also used as the browser's geolocation for
  the search.

### Taxonomy (GBIF)
Only **text names** (e.g. `Sufflamen bursa`, `Lei triggerfish`) are sent to
`api.gbif.org` to resolve canonical names and classification. No image data.
GBIF needs no key and is queried anonymously.

## What is stored
- **No API keys** — nothing here uses one. The only local state is the anonymous
  Chrome profile/cookie jar under `~/.cache/speciestagger-lens` described above.
- Settings live in Lightroom's plugin preferences on your machine.
- This plugin keeps no other data and phones home to nothing else.

## Third-party terms
You are responsible for complying with the terms of the services you use. Note in
particular that Google Lens here is **automated access to a consumer Google
surface** without an official API; Google's Terms of Service discourage automated
access, so use it for your own low-volume personal tagging. Taxonomy uses
[GBIF](https://www.gbif.org/terms). Don't upload images you're not allowed to send
to third parties.
