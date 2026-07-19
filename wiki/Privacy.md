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
  endpoint the Lens website uses) and shown in your **installed Google Chrome** in a
  **visible window** — Google's real results page. **You** read it and **highlight**
  the species name; the plugin then uses only that highlighted text. The plugin does
  not read or scrape the page for you.
- An **anonymous** Google session is used (no account, no login, no cookie to
  paste). So you're not re-accepting Google's cookie/consent screen on every photo,
  the helper keeps a **local Chrome profile + cookie jar** under
  `~/.cache/speciestagger-lens` (or the OS-appropriate cache directory) and reuses
  it across runs — these cookies stay on your machine and are sent only to Google;
  delete that folder to reset. No API key and no third-party host are involved.
  This drives a consumer Google surface in a visible browser, so Google may rate-limit
  or challenge it (run it from a normal home connection); nothing is sent anywhere else.
- If you type **extra search terms** into Google's own search box on the Lens page,
  that text is added to the Lens search and therefore sent to Google as part of the
  query. Nothing else about the photo is sent.

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
Species Tagger is built to **work within Google's Terms of Service**. It does **not
scrape or extract Google's results**: it opens Google Lens in a **visible** browser,
**you** read the page and **highlight** the species name yourself, and the plugin uses
**only that selection** — it performs no automated reading of Google's content and no
bulk access. Taxonomy resolution uses the open [GBIF](https://www.gbif.org/terms) API.
You remain responsible for your own use of third-party services, and shouldn't upload
images you're not allowed to send to them.
