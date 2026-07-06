# FAQ

### Why Google Lens / image search instead of a vision LLM?
For species specifically, Google's reverse-image-search signal was consistently
more accurate in testing than general multimodal models. This plugin uses that
signal and then adds a real taxonomy resolver (GBIF) and a confidence model on
top, so the output is canonical names rather than free-text guesses.

### Does it cost money? Do I need an API key?
No money, and **no API key for anything**. Google Lens is keyless and GBIF (the
taxonomy) is free and keyless. You do need **Node.js** and **Google Chrome**
installed, because Lens has no API and renders results with JavaScript, so the
plugin drives your real Chrome (in a visible window) to run the search. The
released bundle is self-contained — the Lens helper's dependencies ship inside
it, so there's nothing to `npm install`.

### Is it reliable? How accurate is it?
It's **best-effort**. Run it from a normal home (residential) connection —
Google challenges or blocks datacenter/VPN/shared IPs; on any failure the photo
falls through to **needs review**, so it never crashes or double-tags. Accuracy:
the bundled offline test corpus is *representative* (deterministic, seeded from
correct names plus realistic noise) and scores near 100%, but that measures the
**pipeline**, not real Lens recall. Real captures score lower — Lens returns many
related species per image, so the scorer misses some and over-tags others.
Measure the real numbers on your own photos with `just live-accuracy`.

### Does it run on Windows?
Yes — **macOS, Linux, and Windows** are all supported. The Lens helper locates
Chrome on each. On Windows, if Lightroom can't auto-find Node, set the **node
path** in settings (e.g. `C:\Program Files\nodejs\node.exe`).

### Can I add my own keywords to the search?
Yes. At the start of each run the plugin prompts for optional **extra keywords**
that get folded into the Lens image search as text refinement (things like
`juvenile`, `reef`, or a place). Leave it blank for a plain image search, or turn
the prompt off with **Ask for extra keywords each run** in settings.

### Does it use where the photo was taken?
If the photo has GPS or IPTC place fields, the location is used two ways: as the
**browser geolocation** *and* as text added to the Lens search, so Lens favours
species that actually occur there.

### Can I correct wrong tags without re-shooting?
Yes — with **Keep the browser open** on, each photo's Lens results stay in its own
tab. Refine the search in any tab(s) that were wrong (add words, crop, or pick a
different match), then in Lightroom run **Plug-in Extras ▸ Re-tag from open Lens
tabs** once. It sweeps **every** open Lens tab and re-tags each tab's own photo from
your corrected search — no new upload, no marking, no per-photo selection.

### Is the confidence score based on anything?
It's honest but not magic: it's a bounded **evidence score** from 0 to 1, **not
a calibrated probability**. A "0.62" does not mean "62% likely correct" — it's a
monotonic, transparent score used as an operating point. The **Auto-tag
confidence** threshold is where you set that operating point. Ground it in *your*
data by calibrating against your own captures with `just live-accuracy -- --sweep`,
which prints precision/recall at every threshold. Full detail in
[docs/SCORING.md](SCORING.md).

### Why does it sometimes pick an odd common name?
The scientific (Latin) name is always GBIF's accepted name. The common name comes
from what the image search surfaced when available, otherwise from GBIF's
vernaculars — which occasionally aren't the most familiar one. The Latin name is
the unambiguous anchor; rename the common keyword if you prefer another.

### Why GBIF for the names?
GBIF's backbone is free, keyless, and authoritative. It turns a messy web label
into the **accepted** scientific name, gives a **preferred common name**, and
provides the full **Kingdom→Species** classification used for hierarchy keywords.

### Why both common and Latin names?
Common names are searchable and human-friendly; Latin names are unambiguous and
stable across languages and regions. Storing both makes your catalog findable now
and correct later.

### Will it tag two animals in one photo?
Yes — every species that clears the confidence threshold is tagged. Some frames
only surface the dominant subject; crop and re-run for the rest.

### How do I know it's accurate / won't regress?
Run `just accuracy` for a report over the labelled fixture corpus, and
`just test` for the full suite. CI runs both on every push. Add your own photos
to the corpus with `scripts/record-fixture.lua`.

### It mislabelled something — what should I do?
Refine the search and **re-parse** the tab (see above) to replace the tag. You
can also raise or lower the **Auto-tag confidence** threshold to taste, and
calibrate the threshold against your own captures with
`just live-accuracy -- --sweep`. Identification is a fast first pass, not a
substitute for an expert on tricky look-alikes.
