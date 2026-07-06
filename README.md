# Lightroom Species Tagger

Identify the **plants and animals** in your photos and tag them with both the
**common name** and the **Latin (scientific) name** — straight from the Library
module in **Adobe Lightroom Classic**.

It asks **Google Lens** what's in the photo — no paid API, no key — then resolves
every name through the [GBIF](https://www.gbif.org/) taxonomic backbone so the
keywords you get are canonical and consistent — `Octopus cyanea` + `Day octopus`,
not whatever a random web page happened to call it. Optionally it writes the full
taxonomic hierarchy (Kingdom → … → Species) as nested keywords too.

> **Why Google Lens, not a vision LLM?** For species specifically, Google's
> reverse-image-search signal was consistently more accurate in testing than
> general multimodal models. This plugin leans on that signal and adds a real
> taxonomy resolver plus a transparent, tunable confidence model on top — with a
> built-in accuracy harness so quality is measurable and regressions are caught.

- [What it does](#what-it-does)
- [Install (from a release)](#install-from-a-release)
- [Using it](#using-it)
- [Settings](#settings)
- [How it works](#how-it-works)
- [Accuracy — honest numbers, no regressions](#accuracy--honest-numbers-no-regressions)
- [Building from source](#building-from-source)
- [Repository layout — authored vs. generated](#repository-layout--authored-vs-generated)
- [Privacy](#privacy) · [Limitations](#limitations) · [Contributing](#contributing) · [License](#license)

## What it does

- **One command** tags every selected photo with its species (common + Latin name).
- **Multi-subject frames work:** every species that clears the confidence threshold
  is tagged, so a reef shot with a fish *and* an octopus gets both.
- **Uncertain?** The photo gets a `species: needs review` keyword instead of a guess.
- **Adds context to the search:** it can fold the photo's **location** and any
  **extra keywords you type** into the Lens search (see [Using it](#using-it)).
- **Correct a wrong result** without re-shooting: refine the search in the browser
  tab it left open and **re-parse** it to re-tag the photo.
- **Cross-platform:** macOS, Linux, and Windows.

## Install (from a release)

You need **Node.js** and **Google Chrome** installed (that's what runs the Lens
search). Then:

1. Download the latest `SpeciesTagger.lrplugin-*.zip` from
   [Releases](https://github.com/yoren/lightroom-species-tagger/releases) and unzip.
   The bundle is **self-contained** — the Lens helper's dependencies are already
   inside it, so there's nothing to `npm install`.
2. Lightroom Classic → **File ▸ Plug-in Manager ▸ Add** → select the
   `SpeciesTagger.lrplugin` folder.
3. The first time you run it, a short **welcome** lists every setting and where to
   find it. Open **Plug-in Manager ▸ Species Tagger** any time to adjust them.
4. Select photos in the Library, then **Library ▸ Plug-in Extras ▸ Identify and
   Tag Species**.

> Google gates the Lens endpoint on the **network you run from** — use a normal home
> (residential) connection; datacenter/VPN/shared IPs get challenged or blocked. On
> any failure a photo simply falls through to *needs review* — it never crashes or
> mis-tags.

## Using it

Select one or more photos and run **Library ▸ Plug-in Extras ▸ Identify and Tag
Species**. A Chrome window opens showing Google's real results page (never a hidden
scrape); if Google shows an "are you human" check on a single-photo run, a bar lets
you solve it and continue.

Each run can add text to the image search so Lens weighs picture **and** words:

- **Extra keywords** — you're prompted at the start of each run (toggle this off in
  settings). Type things like `juvenile`, `reef`, or a place; leave blank for a
  plain image search.
- **Location** — if the photo has GPS or IPTC place fields, the location is used as
  browser geolocation *and* added to the search text as `in <place>` (e.g.
  `in Monterey, California`), so Lens reads it as *where the photo was taken* — a
  locality hint that favours species occurring there — rather than as the subject.

**Correcting results (re-parse).** Turn on **Keep the browser open** in settings.
Now each photo's results stay in its own tab. Fix as many as you like — refine the
search in any tab(s) (Lens lets you add words, crop, or pick a different match) —
then in Lightroom run **Plug-in Extras ▸ Re-parse Open Lens Tabs & Re-tag** once. It
sweeps **every** open Lens tab, re-tags each tab's own photo from your corrected
search (no new upload, no marking, no per-photo selection), and reports what changed.

## Settings

Open **Plug-in Manager ▸ Species Tagger**.

| Setting | What it does |
|---|---|
| Keep the browser open | Reuse one Chrome window (a tab per photo) so you can refine + re-parse a search |
| node path | Set only if Lightroom can't auto-find Node (its GUI gets a minimal PATH) — e.g. `/opt/homebrew/bin/node` or `C:\Program Files\nodejs\node.exe` |
| Keywords | `flat` (common + Latin), `hierarchy` (Kingdom→Species), or `both` |
| Hierarchy root | Optional parent keyword to nest the tree under (e.g. `Wildlife`) |
| Auto-tag confidence | The operating point (0.30–0.95) above which tags apply automatically — see [Accuracy](#accuracy--honest-numbers-no-regressions) |
| Needs-review tag | Keyword applied when nothing clears the threshold |
| Include applied keywords on export | Whether the keywords travel with exported files |
| Ask for extra keywords each run | Whether to prompt for extra Lens-search keywords |

## How it works

```
 photo ─▶ downsized JPEG ─▶ Google Lens ─▶ observations ─▶ parser ─▶ candidates
          (fresh render,     (via your      (AI overview +   (sci + common names)
           EXIF/GPS stripped) real Chrome)    match titles)          │
   keywords ◀── plan (flat + hierarchy) ◀── ranked taxa ◀── GBIF resolve + score
```

1. **Google Lens** (`src/shared/ProviderGoogleLens.lua` + the Node helper
   `scripts/lens`): Lens has no anonymous API and renders results with JavaScript,
   so a small helper uploads the image, transplants the anonymous session into your
   installed Chrome, lets it render, and returns the visible match text — Google's
   own AI-Overview answer plus the titles of pages showing the same image.
2. **Parser** (`SpeciesParser.lua`) mines two channels: scientific binomials
   (`Genus species`) and cleaned common-name candidates, ranked by how strongly and
   how often they appear.
3. **Taxonomy** (`Taxonomy.lua`) resolves each candidate against **GBIF** (free, no
   key): a scientific name is confirmed by exact match; a common name is looked up
   and normalised to its accepted species, with the full classification chain.
4. **Scorer** (`Identify.lua`) combines the evidence into a confidence per taxon.
   Lens's AI Overview is treated as the authoritative answer; the noisy visual-match
   titles only corroborate. See [Accuracy](#accuracy--honest-numbers-no-regressions)
   for exactly what the number means.
5. **Keywording** (`Keywords.lua`) writes the result: flat `common` + `Latin`
   keywords, the full hierarchy, or both.

The image-recognition step sits behind one small **provider seam**, so the whole
parser → GBIF → scorer pipeline is pure, unit-tested, and unchanged no matter what
feeds it.

## Accuracy — honest numbers, no regressions

This is built to be **measurable**, not vibes.

```
just test        # unit + accuracy specs (busted) — fully offline, no API keys
just accuracy    # prints recall / top-1 / genus / family / false+ over the corpus
```

Each case in `spec/fixtures/manifest.lua` pairs a recorded Lens response with
ground-truth species and replays it through the **real** parser/scorer/resolver.
CI runs it on every push, so a change that quietly drops accuracy fails the build.

**Two honesty notes worth reading:**

- **The bundled Lens fixtures are *representative*, not live captures.** The GBIF
  responses are real; the `spec/fixtures/lens/*.json` blobs are seeded from the
  correct names plus realistic noise. So the offline 100% proves the **pipeline**
  works on Lens-shaped input — it is *not* a measurement of real Lens recall. Measure
  the real thing on your own photos with `just live-accuracy` (residential network).
- **The confidence number is a bounded *evidence score*, not a calibrated
  probability.** A "0.62" doesn't mean "62% correct"; it's a monotonic, transparent
  score (the exact formula is in `Identify.lua`) used as an operating point. Ground
  the threshold in *your* data with the calibration sweep:

  ```
  just live-accuracy -- --sweep    # precision / recall at every threshold
  ```

  Full detail: [docs/SCORING.md](docs/SCORING.md).

## Building from source

Everything is driven by scripts at the repo root (macOS / Linux; on Windows use WSL
for the dev toolchain — Windows *end users* just download the release):

```
./install.sh       # one-shot: toolchain + Lens helper deps + build + symlink into Lightroom
./dev-setup.sh     # just the pinned Lua 5.1 + LuaRocks toolchain (.lua-env)
./build.sh         # build dist/SpeciesTagger.lrplugin (+ zip + checksums)
./debug-lens.sh    # troubleshoot a wrong ID in a visible Chrome with debug artifacts
```

Or the finer-grained [`just`](https://github.com/casey/just) recipes:

```
just check         # lint + test + build (run before pushing)
just lint          # luacheck src spec scripts
just test          # busted unit + accuracy specs
just lens-test     # drive the real Lens helper against a fake Google (needs Chrome)
just build         # compose the bundle, version-stamp, zip + checksums
just install       # build + symlink into the local Lightroom Modules folder
```

There is no build step to memorise and **no AI in the loop**: `just check` is the
whole gate, and it's exactly what CI runs.

## Repository layout — authored vs. generated

*(Answering the reasonable question "is all that code in `node_modules` / `.deps`
ours?" — no. Here's every tree and who wrote it.)*

**Authored (this is the project):**

```
src/shared/                 pure, testable modules (parser, taxonomy, scorer, keywords, provider)
src/SpeciesTagger.lrplugin/ the Lightroom glue (menus, settings, catalog writes)
scripts/lens/               the Google Lens browser helper (lens-search.js, overlay-inject.js, tests)
scripts/*.lua               dev tooling (accuracy, corpus builders, live-accuracy, record-fixture)
spec/                       unit specs + the accuracy harness + the labelled fixture corpus
build/build.lua             composes/stamps/zips the bundle
docs/, *.sh, justfile       docs + entry-point scripts
```

**Generated or third-party — never committed, all reproducible, all git-ignored:**

Everything the build *produces* lives under one top-level **`output/`** tree, removed
by **`just clean`**:

| Tree | What it is | Ours? | How it appears |
|---|---|---|---|
| `output/dist/` | The built `.lrplugin` bundle + zips | generated | `./build.sh` |
| `output/deps/` | The one Lua runtime dep (`dkjson`) | third-party | pulled by LuaRocks at build |

Two dependency trees can't live under `output/` (their tools require a fixed
location) — `just clean-all` removes them too:

| Tree | What it is | Ours? | Why it's separate |
|---|---|---|---|
| `scripts/lens/node_modules/` | `puppeteer-core` (pure JS) | third-party | Node resolves modules next to `package.json` |
| `.lua-env/` | Pinned Lua 5.1 + LuaRocks toolchain | third-party | your installed dev env, not build output |

The only third-party **runtime** code that ships inside the `.lrplugin` is `dkjson`
(JSON) and `puppeteer-core` (drives your Chrome). Taxonomy uses GBIF over `LrHttp`;
there's no SDK to vendor.

## Privacy

A **downsized, freshly-rendered** JPEG (so no original EXIF/GPS) is uploaded to
Google Lens. No third-party image host is involved. Taxonomy lookups send only
**names** to GBIF. Full detail in [docs/PRIVACY.md](docs/PRIVACY.md).

## Limitations

- Identifies to **species** (sometimes genus); subspecies and ambiguous look-alikes
  may land in *needs review*. It's a fast first pass, not a taxonomist.
- Accuracy is only as good as the image-search signal — clear, well-framed subjects
  do best, and real Lens returns many related species per image.
- The Lens backend is **best-effort and unofficial** (it automates a consumer Google
  surface). Keep batches modest; run from a residential network.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — how to set up in one command, the test/lint
gate, the architecture, and how to grow the corpus. Issues and PRs welcome.

## License

[MIT](LICENSE) © 2026 Yuval Oren
