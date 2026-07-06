# Troubleshooting

### Google Lens: “helper produced no output” / “is Node and Google Chrome installed?”
The Lens step drives your installed Chrome via a bundled Node helper. Check:
- **Node + Chrome installed.** The released bundle ships the helper's deps, so
  there's nothing to `npm install`.
- If `node` isn't found (Lightroom's GUI gets a minimal PATH), set the **node
  path** in **Plug-in Manager → Species Tagger** — e.g. `/opt/homebrew/bin/node`
  on macOS, `/usr/bin/node` on Linux, or `C:\Program Files\nodejs\node.exe` on
  Windows.
- Run from a normal home (residential) connection — Google challenges or blocks
  datacenter/VPN/shared IPs.
Affected photos are left at **needs review**, not mis-tagged.

### Lens over-tags / tags the wrong species
Real Lens returns many related species per image, so the scorer can apply extras.
Options:
- Raise the **Auto-tag confidence** threshold so only strong hits apply.
- Calibrate the threshold on your own captures with `just live-accuracy -- --sweep`
  (precision/recall at every threshold).
- Crop to a single subject and re-run.
- Or, with **Keep the browser open** on, refine the search in the tab and
  **re-parse** it (see *Wrong species applied* below).
(The offline corpus is representative and won't show over-tagging; real captures do.)

### Everything comes back “species: needs review”
Nothing cleared the confidence threshold. Common causes:
- The subject is small, blurry, or one of several things in frame — crop closer
  and retry.
- Lens returned weak or generic labels (or was blocked — see above).
- Your threshold is high — lower **Auto-tag confidence** (e.g. to 0.50) in settings.
- Adding **extra keywords** or a **location** to the run can steer Lens toward a
  stronger match.
The best guess is shown in the run summary even when it isn't auto-applied.

### Wrong species applied
Correct it in place instead of re-shooting:
1. Turn on **Keep the browser open** in settings so each photo's results stay in
   its own tab.
2. Refine the search in any tab(s) that were wrong (add words, crop, or pick a
   different match).
3. In Lightroom, run **Plug-in Extras ▸ Re-parse Open Lens Tabs & Re-tag**. It
   sweeps every open Lens tab and re-tags each tab's own photo — no new upload, no
   marking, no per-photo selection.

You can also raise the **Auto-tag confidence** threshold so only strong hits
apply, and let look-alikes go to review. Recording a fixture for the photo
(`scripts/record-fixture.lua`) makes a failure reproducible for tuning.

### Re-parse says a tab is “unmatched”
Re-parse re-tags each tab's own photo using the path stamped on the tab when it was
opened. A tab shows as *unmatched* only if it has no stamp — e.g. a Lens tab you
opened by hand, or one from before this feature. Re-run *Identify and Tag Species*
(with **Keep the browser open** on) to open properly-stamped tabs. If the whole
window was closed, re-run to open fresh tabs.

### It identified only one of two animals
Expected for some frames — the search focuses on the dominant subject. Crop to the
second subject and run again; both sets of keywords accumulate on the photo.

### HEIC / raw files
The plugin uses Lightroom's own preview rendering, so any format Lightroom can
preview (raw, HEIC, etc.) works — no separate HEIC conversion needed.

### Rate limits / throttling
Lens has no published quota, but it's automated access to a consumer Google
surface, so Google may throttle or challenge it. Run from a residential
connection and keep batches modest; on any block the affected photos land at
**needs review**.

### Reset
Removing keywords the plugin added is a normal Lightroom keyword operation. To
start clean, delete the keywords (and the `species: needs review` keyword) from
the Keyword List panel. To reset the Lens session, delete the local Chrome
profile/cookie jar (see [Privacy](PRIVACY.md)).
