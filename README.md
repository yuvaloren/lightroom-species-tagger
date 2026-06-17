# Lightroom Species Tagger

Identify the **plants and animals** in your photos and tag them with both the
**common name** and the **Latin (scientific) name** — straight from the Library
module in **Adobe Lightroom Classic**.

It asks an image-recognition backend what's in the photo — by default **Google
Lens directly** (no paid API, no key) — then resolves every name through the
[GBIF](https://www.gbif.org/) taxonomic backbone so the keywords you get are
canonical and consistent — `Octopus cyanea` + `Day octopus`, not whatever a
random web page happened to call it. Optionally it writes the **full taxonomic
hierarchy** (Kingdom → … → Species) as nested keywords too.

> Why not just a vision LLM? In testing, general multimodal models (Gemini, etc.)
> were noticeably less accurate at species than Google Lens / reverse-image
> search. This plugin leans on that image-search signal and adds a real taxonomy
> resolver on top, with a built-in accuracy harness so quality is measurable and
> regressions are caught.

## How it works

```
 photo ─▶ downsized JPEG ─▶ provider ─▶ observations ─▶ parser ─▶ candidates
                            (Lens|Vision)  (labels+titles)  (sci + common names)
                                                                     │
   keywords ◀── plan (flat + hierarchy) ◀── ranked taxa ◀── GBIF resolve + score
```

1. **Provider** (pluggable): asks Google what's in the image and returns a
   normalised list of *observations* — Google's own label guesses plus the
   titles of pages showing the same image.
2. **Parser** mines two channels from those: scientific binomials (`Genus
   species`) and cleaned common-name candidates, ranked by how often and how
   strongly they appear.
3. **Taxonomy** resolves each candidate against **GBIF** (free, no key): a
   scientific name is confirmed by exact match; a common name is looked up and
   normalised to its accepted species, with the full classification chain.
4. **Scorer** combines the evidence into a confidence per taxon. When a
   scientific *and* a common candidate independently agree on the same species,
   confidence jumps — that agreement is the core signal.
5. **Keywording** writes the result: flat `common` + `Latin` keywords, the full
   hierarchy, or both (your choice). Confident hits are applied automatically;
   anything uncertain gets a `species: needs review` tag instead of a guess.

Multi-subject frames work: every species clearing the threshold is tagged, so a
reef shot with a fish *and* an octopus gets both.

## Backends

| Backend | What it is | Cost / setup | Coverage | Notes |
|---|---|---|---|---|
| **Google Lens** *(default)* | Talks to Google Lens directly — uploads the image and harvests the match data from the results page | **Free, no key** — self-generates a Google session via `curl` (macOS/Linux); optional cookie fallback | plants + animals | Closest to the Lens app; best-effort (see below) |
| **Pl@ntNet** | [Pl@ntNet](https://my.plantnet.org/) identification API | **Free key**, 500/day, no credit card | **plants only** | Rock-solid for flora; returns clean scientific + common names |
| **Google Vision (Web Detection)** | [Cloud Vision web detection](https://cloud.google.com/vision/docs/detecting-web) | Needs a **GCP billing account** (card on file; ~1,000 free/mo then paid) | plants + animals | Most reliable, ToS-clean; opt in only if a card is OK |

All three send the image bytes directly (no third-party image host) and feed the
**identical** parser → GBIF → scorer pipeline, so the accuracy logic is shared and
testable regardless of backend.

> **On the default (Google Lens):** there is no official Google Lens API, and
> Google requires a genuine **browser session** (real cookies; even Safari works,
> so it's the session that matters, not Chrome-specific headers). The plugin can't
> use `LrHttp` for this (it drops the session cookie across the upload→results
> redirect), so it **shells out to `curl`** and **self-generates a session** — a
> warm-up request to google.com yields fresh cookies, exactly like a fresh
> incognito window. No key, no paste. (If your network refuses the self-generated
> session, paste a browser Cookie value in settings as a fallback.) Best-effort: a
> flagged network makes a photo fall through to *needs review* (it never crashes),
> and you can switch to Pl@ntNet/Vision. The parser harvests names (rather than
> walking fragile fixed offsets), so it degrades gracefully when Google changes the
> page. macOS/Linux only for now (`curl` + POSIX shell). You can validate/refresh
> the offline corpus the same way with `just refresh-fixtures`.

## Requirements

- Adobe Lightroom Classic (built against SDK ≥ 6 APIs).
- For the backend you pick:
  - **Google Lens (default):** no key, no setup — self-generates a Google session
    (macOS/Linux; needs `curl` on PATH). Optional cookie fallback in settings.
  - **Pl@ntNet:** a free [Pl@ntNet](https://my.plantnet.org/) API key (no credit card).
  - **Vision:** a [Google Cloud Vision](https://cloud.google.com/vision) API key
    (requires a GCP project with billing enabled).
- No key needed for GBIF (taxonomy) — it's free and anonymous.

## Install

1. Download the latest `SpeciesTagger.lrplugin-*.zip` from
   [Releases](https://github.com/yoren/lightroom-species-tagger/releases) and unzip.
2. Lightroom Classic → **File → Plug-in Manager → Add** → select the
   `SpeciesTagger.lrplugin` folder. (Or drop it into your `Modules` folder:
   macOS `~/Library/Application Support/Adobe/Lightroom/Modules/`,
   Windows `%APPDATA%\Adobe\Lightroom\Modules\`.)
3. In **Plug-in Manager**, open the **Species Tagger** settings and:
   - pick your **backend** (the default, Google Lens, needs no key; Pl@ntNet and
     Vision each take their key);
   - choose your **keyword style** (flat / hierarchy / both) and the
     **auto-apply threshold**.
4. Select photos in the Library, then **Library → Plug-in Extras → Identify and
   Tag Species**.

## Settings

| Setting | What it does |
|---|---|
| Backend | `lens` (Google Lens, direct & keyless), `plantnet`, or `vision` |
| Pl@ntNet / Vision key | Credentials for the chosen keyed backend (stored in Lightroom prefs) |
| Lens locale | `hl` / `country` passed to the Lens upload |
| Keywords | `flat` (common + Latin), `hierarchy` (Kingdom→Species), or `both` |
| Hierarchy root | Optional parent keyword to nest the tree under (e.g. `Wildlife`) |
| Auto-apply at | Confidence threshold (0.30–0.95) above which tags are applied automatically |
| Needs-review tag | Keyword applied when nothing clears the threshold |

## Accuracy & testing — no regressions

This is built to be **measurable**, not vibes. The repo ships a labelled
**fixture corpus** and an offline harness:

```
just test        # unit + accuracy specs (busted) — fully offline, no API keys
just accuracy    # prints the accuracy table (recall / top-1 / genus / family / false+)
```

Each case in `spec/fixtures/manifest.lua` pairs a recorded provider response
with ground-truth species. The harness replays it through the real
parser/scorer/resolver (the GBIF responses are **real captures**; the Lens/Vision
responses are representative until you record your own), and asserts both
**recall** (every expected species found) and **precision** (no confident false
positives). CI runs it on every push, so a change that quietly drops accuracy
fails the build.

The seed corpus is built from the maintainer's own Instagram captions
(`spec/fixtures/groundtruth/yuvalsaw.lua` is the full labelled set). Grow it with
**real** captures from your own photos:

```
lua scripts/record-fixture.lua spec/fixtures/images/yourshot.jpg --provider lens
# (writes the provider + GBIF fixtures and prints a manifest stub to paste in)
# Lens needs a residential connection; for plants: PLANTNET_KEY=… --provider plantnet
```

### Are the bundled Lens fixtures real?

**No — by default they are *representative*, not live Google captures.** The GBIF
fixtures are real, but the `spec/fixtures/lens/*.json` blobs are generated
(`scripts/build-corpus.lua`'s `lensBlob`) — seeded with the correct species names
plus noise — because Google blocks automated Lens access from datacenter/CI IPs.
So the offline 100% number proves the **parser → GBIF → scorer pipeline** works on
Lens-shaped input; it is **not** a measurement of real Google Lens recall.

To measure (and verify) the real thing, refresh the fixtures from live Google Lens
on a **residential** connection:

```
just refresh-fixtures          # = build-corpus.lua --corpus --live
just accuracy                  # now scores the REAL captures against the ground truth
```

This overwrites each corpus `lens/*.json` with Google's actual output and saves
Google's **raw HTML** to `spec/fixtures/lens/raw/<case>.html` so you can audit that
the captures are genuinely Google's and that the parser extracts them faithfully
(neither is committed). The `expected` labels stay the human ground truth, so the
accuracy run can legitimately come in below 100% — that's the honest signal.

## Building & developing

One self-contained script bootstraps a fresh machine (isolated, pinned Lua 5.1 +
LuaRocks via [hererocks](https://github.com/luarocks/hererocks), matching CI and
the Lightroom runtime):

```
bash scripts/dev-setup.sh        # or: just setup
```

Everyday commands (each is a one-liner if you don't use [`just`](https://github.com/casey/just)):

```
just lint        # luacheck src spec scripts
just test        # busted unit + accuracy specs
just accuracy    # accuracy report over the fixture corpus
just build       # compose dist/SpeciesTagger.lrplugin, version-stamp, zip + checksums
just install     # build + symlink into the local Lightroom Modules folder
just check       # lint + test + build (run before pushing)
```

### Layout

```
src/shared/        pure, testable modules (parser, taxonomy, scorer, keywords, providers)
src/SpeciesTagger.lrplugin/  the Lightroom glue (menu, settings, catalog writes)
spec/              unit specs + the accuracy harness + fixture corpus
build/build.lua    composes/stamps/zips the bundle; pulls the one runtime dep (dkjson)
scripts/           dev-setup, install, accuracy report, fixture recorder
```

The only third-party **runtime** dependency is **dkjson** (JSON), pinned in
`build/build.lua`, pulled at build time and bundled into the `.lrplugin` (never
committed). Taxonomy uses GBIF over `LrHttp`; there's no SDK to vendor.

## Privacy

A **downsized, freshly-rendered** JPEG (so no original EXIF/GPS) is sent to the
chosen backend: Google (Lens or Vision) or Pl@ntNet. No third-party image host is
involved on any path. Taxonomy lookups send only **names** to GBIF. Full detail in
[docs/PRIVACY.md](docs/PRIVACY.md).

## Limitations

- Identifies to **species** (sometimes genus); subspecies and ambiguous
  look-alikes may land in “needs review”. Treat it as a fast first pass, not a
  taxonomist.
- Accuracy is only as good as the image-search signal — clear, well-framed
  subjects do best.
- The bundled Lens/Vision fixtures are representative; record real ones for a
  true accuracy read on your own library.

## License

[MIT](LICENSE) © 2026 Yuval Oren
