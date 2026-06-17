# Troubleshooting

### “Add your free Pl@ntNet API key …” / “Add your Google Vision API key …”
The selected backend needs a key. Open **Plug-in Manager → Species Tagger** and
paste the key for the backend you chose — or switch the backend to **Google Lens
(direct)**, which needs no key.

### Google Lens: “helper produced no output” / “is Node and Google Chrome installed?”
The Lens backend drives your installed Chrome via a bundled Node helper. Check:
- **Node + Chrome installed**, and the helper's deps: `cd scripts/lens && npm i`.
- If `node` isn't found (Lightroom's GUI has a minimal PATH), set the **node path**
  in **Plug-in Manager → Species Tagger** (e.g. `/opt/homebrew/bin/node`).
- Run from a normal home connection — Google blocks datacenter/VPN/shared IPs.
- macOS/Linux only for now.
Or switch the backend to **Pl@ntNet** (plants) or **Google Vision**. Affected
photos are left at **needs review**, not mis-tagged.

### Lens over-tags / tags the wrong species
Real Lens returns many related species per image, so the scorer can apply extras.
Raise the **Auto-apply** threshold so only strong hits apply, run `just
live-accuracy` to see how it does on your photos, and prefer cropping to one
subject. (The offline corpus is representative and won't show this; real captures
do.)

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
