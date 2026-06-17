# Troubleshooting

### “Add your free Pl@ntNet API key …” / “Add your Google Vision API key …”
The selected backend needs a key. Open **Plug-in Manager → Species Tagger** and
paste the key for the backend you chose — or switch the backend to **Google Lens
(direct)**, which needs no key.

### Google Lens: “blocked (403 / consent)”, “rate-limiting … unusual traffic”, or “not associated … re-upload”
Lens self-generates a Google session, but your network refused it (common on
shared/VPN/datacenter connections, or behind CGNAT). Options, in order:
- Run from a normal home connection in smaller selections, and wait before
  retrying (limits clear within minutes to hours). Needs `curl` on PATH (macOS/Linux).
- Provide the optional cookie fallback: in a browser where lens.google.com works,
  DevTools → Network → run a Lens image search → click the `upload` request → copy
  its whole **Cookie** header value (include `NID` and `AEC`) → paste into
  **Plug-in Manager → Species Tagger → Lens cookie**.
- Switch the backend to **Pl@ntNet** (plants) or **Google Vision** for a
  sanctioned, key-based API that isn't rate-limited this way.
The affected photos are left at **needs review**, not mis-tagged.

### Everything comes back “species: needs review”
Nothing cleared the confidence threshold. Common causes:
- The subject is small, blurry, or one of several things in frame — crop closer
  and retry.
- The backend returned weak or generic labels (or Lens was blocked — see above).
  Try another backend.
- Your threshold is high — lower **Auto-apply at** (e.g. to 0.50) in settings.
The best guess is shown in the run summary even when it isn't auto-applied.

### Pl@ntNet returns nothing for my animal photo
Pl@ntNet identifies **plants only**. For animals use the Google Lens or Vision
backend.

### Wrong species applied
- Lower-confidence look-alikes happen. Raise the threshold so only strong hits
  apply, and let the rest go to review.
- Record a fixture for the photo (`scripts/record-fixture.lua`) and open an
  issue — it makes the failure reproducible and helps tune the parser/scorer.

### It identified only one of two animals
Expected for some frames — the search focuses on the dominant subject. Crop to the
second subject and run again; both sets of keywords accumulate on the photo.

### HEIC / raw files
The plugin uses Lightroom's own preview rendering, so any format Lightroom can
preview (raw, HEIC, etc.) works — no separate HEIC conversion needed.

### Rate limits / quota
- **Lens (direct):** no quota, but Google may throttle automated access — keep
  batches modest (see the block message above).
- **Pl@ntNet:** 500 identifications/day on the free tier.
- **Vision:** ~1,000 units/month free, then billed. Run large jobs in smaller
  selections.

### Reset
Removing keywords the plugin added is a normal Lightroom keyword operation. To
start clean, delete the keywords (and the `species: needs review` keyword) from
the Keyword List panel.
