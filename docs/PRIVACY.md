# Privacy & data flow

This plugin sends image data to a third-party service to recognise subjects. Here
is exactly what leaves your machine, and when.

## What is sent

Before anything is sent, the photo is rendered to a **downsized JPEG**
(longest edge ≈ 1024 px by default). Because it's a fresh render, the original
**EXIF/GPS metadata is not included** in what's sent. No backend uses a
third-party image host — the bytes go straight to the recognition service.

### Google Lens (browser session) backend — the default
- The downsized JPEG **bytes** are uploaded directly to `lens.google.com`
  (multipart, the same endpoint the Lens website uses); the results page is then
  read back and parsed locally.
- Because Lens has no anonymous API, the plugin **shells out to `curl`** and sends
  the **Google session cookie you pasted in settings** (so Google treats it like
  your browser). That cookie is stored in Lightroom's plugin preferences on your
  machine and sent only to Google; it is redacted in logs. No API key and no
  third-party host are involved. This is automated access to a consumer Google
  surface, so Google may rate-limit or block it; nothing is sent anywhere else.

### Pl@ntNet backend
- The downsized JPEG **bytes** are uploaded to `my-api.plantnet.org` with your
  Pl@ntNet API key. Nothing is uploaded to any other host.

### Google Vision backend
- The downsized JPEG **bytes** are sent (base64, inline) to
  `vision.googleapis.com` with your API key (HTTPS). Nothing else is uploaded.

### Taxonomy (GBIF)
Only **text names** (e.g. `Sufflamen bursa`, `Lei triggerfish`) are sent to
`api.gbif.org` to resolve canonical names and classification. No image data.
GBIF needs no key and is queried anonymously.

## What is stored
- Your API keys (Pl@ntNet / Vision) are stored in Lightroom's plugin preferences
  on your machine. The default Lens backend stores no credentials.
- Logs (Lightroom's plugin log) **redact** API keys.
- This plugin keeps no other data and phones home to nothing else.

## Third-party terms
You are responsible for complying with the terms of the services you enable.
Note in particular that the **Google Lens (direct)** backend automates access to
Google without an official API; Google's Terms of Service discourage automated
access, so use it for your own low-volume tagging and switch to
[Pl@ntNet](https://my.plantnet.org/) or [Google Cloud
Vision](https://cloud.google.com/terms) if you'd rather use a sanctioned API.
Taxonomy uses [GBIF](https://www.gbif.org/terms). Don't upload images you're not
allowed to send to third parties.
