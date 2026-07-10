# Lightroom Species Tagger

[![CI](https://github.com/yuvaloren/lightroom-species-tagger/actions/workflows/ci.yml/badge.svg)](https://github.com/yuvaloren/lightroom-species-tagger/actions/workflows/ci.yml)

Tag the **plants and animals** in your photos with both the **common name** and the
**Latin (scientific) name** — straight from the Library module in **Adobe Lightroom
Classic**. This plugin uses Google Lens searches, as based on personal experience that 
service seems to be more accurate than the Google Vision API.

For each selected photo it opens **Google Lens** in a visible Chrome window. **You** read Google's results and **highlight** the species name;
press **Tag** at the bottom bar, and the plugin resolves your pick through the
[GBIF](https://www.gbif.org/) taxonomy service and writes canonical keywords to the
image.

> **Assistive by design.** The plugin doesn't read Google's results for you — you do,
> and it uses only the name you highlight, in order to allow follow-up refinement and
> comply with Google's terms of service.

**Download the installer:**
[**macOS** (.pkg — Apple Silicon & Intel)](https://github.com/yuvaloren/lightroom-species-tagger/releases/latest/download/SpeciesTagger-mac.pkg) ·
[**Windows** (.exe)](https://github.com/yuvaloren/lightroom-species-tagger/releases/latest/download/SpeciesTagger-win-setup.exe) —
run it, restart Lightroom, then **Library ▸ Plug-in Extras ▸ Identify and Tag Species**.
Full guide on the [wiki](https://github.com/yuvaloren/lightroom-species-tagger/wiki).

- [What it does](#what-it-does)
- [Install (from a release)](#install-from-a-release)
- [Using it](#using-it)
- [Settings](#settings)
- [How it works](#how-it-works)
- [Building from source](#building-from-source)
- [Repository layout — authored vs. generated](#repository-layout--authored-vs-generated)
- [Privacy](#privacy) · [Limitations](#limitations) · [Contributing](#contributing) · [License](#license)

## What it does

- **You highlight, it tags.** For each photo it opens Google Lens; you read the
  results, **highlight** the species name and press **Tag** — it writes the common +
  Latin keywords to that photo.
- **Canonical names, always.** Whatever you highlight (a common name or a binomial) is
  resolved through **GBIF** to the accepted scientific name, preferred common name, and
  (optionally) the full Kingdom → Species hierarchy.
- **Refine in Google's own box.** Add keywords or crop in Lens's search box to sharpen
  the results before you pick (see [Using it](#using-it)).
- **One window, m-of-n.** Multi-photo runs reuse a single Chrome window with a "Photo 2
  of 5" counter; **Skip** leaves a photo untouched.
- **Cross-platform:** macOS and Windows.

## Install (from a release)

You must have **Google Chrome** and **Adobe Lightroom Classic** installed.

### The easy way — one-click installer

1. Download and run the installer for your OS:
   [**macOS** — `SpeciesTagger-mac.pkg`](https://github.com/yuvaloren/lightroom-species-tagger/releases/latest/download/SpeciesTagger-mac.pkg)
   (one universal build for Apple Silicon *and* Intel) or
   [**Windows** — `SpeciesTagger-win-setup.exe`](https://github.com/yuvaloren/lightroom-species-tagger/releases/latest/download/SpeciesTagger-win-setup.exe).
   No admin rights needed; the plugin lands in Lightroom's auto-load `Modules`
   folder for the current user, so there are **no Plug-in Manager steps**.
2. Start (or restart) Lightroom Classic.
3. Select photos in the Library, then **Library ▸ Plug-in Extras ▸ Identify and
   Tag Species**.

> **Windows note (temporary):** the installer isn't code-signed yet, so SmartScreen
> may show *"Windows protected your PC"* — click **More info ▸ Run anyway**. (The
> macOS installer is signed and notarized; Windows code signing is in progress.)

To uninstall: **Windows** — Settings ▸ Apps ▸ Species Tagger (or run
`Uninstall.exe` in the plugin folder); **macOS** — delete
`~/Library/Application Support/Adobe/Lightroom/Modules/SpeciesTagger.lrplugin`.

### The manual way — zip + Plug-in Manager

1. Download the zip for your OS from
   [Releases](https://github.com/yuvaloren/lightroom-species-tagger/releases):
   `SpeciesTagger-<version>-mac.zip` (macOS — one universal build for Apple Silicon
   *and* Intel) or `SpeciesTagger-<version>-win.zip` (Windows).
   (`SpeciesTagger-<version>-all.zip` carries both OSes in one — it's the package
   single-download channels like Adobe Exchange use; you don't need it.)
   Every zip is **self-contained** — it ships its own Node runtime *and* the Lens
   helper's dependencies, so there's no Node to install and nothing to `npm install`.
2. Unzip it:
   - **macOS:** double-click the zip — you get the `SpeciesTagger.lrplugin` folder.
   - **Windows:** right-click ▸ **Extract All** — Windows wraps the result in a
     `SpeciesTagger-<version>-win` folder; the plugin is the `SpeciesTagger.lrplugin`
     folder **inside** it.
3. Lightroom Classic → **File ▸ Plug-in Manager ▸ Add** → select that
   `SpeciesTagger.lrplugin` folder.
4. The first time you run it, a short **welcome** lists every setting and where to
   find it. Open **Plug-in Manager ▸ Species Tagger** any time to adjust them.
5. Select photos in the Library, then **Library ▸ Plug-in Extras ▸ Identify and
   Tag Species**.

> Google gates the Lens endpoint on the **network you run from** — use a normal home
> (residential) connection; datacenter/VPN/shared IPs get challenged. If a check
> appears, solve it in the window and carry on; a photo you don't tag is just left
> untouched.

## Using it

Select one or more photos and run **Library ▸ Plug-in Extras ▸ Identify and Tag
Species**. For each photo a Chrome window opens showing Google's real results page,
with a small **Species Tagger** bar across the bottom. Then:

1. **Read the results.** Refine them in **Google's own search box** if you like (add
   words like `juvenile` or `reef`, crop, pick a different match).
2. **Highlight the species' Latin name** on the page (a common name works too — GBIF
   resolves either).
3. **Press Tag** in the Species Tagger bar at the **bottom** of the window. The plugin
   resolves your selection through GBIF and writes the common + Latin keywords to that
   photo.

Press **Skip** to leave a photo untagged.

## Settings

Open **Plug-in Manager ▸ Species Tagger**.

| Setting | What it does |
|---|---|
| Keywords | `flat` (common + Latin), `hierarchy` (Kingdom→Species), or `both` |
| Include applied keywords on export | Whether the keywords travel with exported files |

## How it works

```
 photo ─▶ downsized JPEG ─▶ Google Lens ─▶ YOU read + highlight ─▶ Tag
          (fresh render,     (visible          the species name    (button on
           EXIF/GPS stripped) Chrome window)    on Google's page     the page)
                                                                       │
        keywords ◀── plan (flat + hierarchy) ◀── canonical taxon ◀── GBIF resolve
```

1. **Google Lens** (`src/shared/Http.lua` + the Node helper `scripts/lens`): the
   helper uploads the downsized image and opens Google Lens in your installed Chrome —
   a **visible** window showing Google's real results, with a small bottom bar (a Tag
   button, a Skip button, and an "m of n" counter). The plugin does not read the page.
2. **You choose** — read the results, refine in Google's own search box if you like, and
   **highlight** the species name. Pressing **Tag** reads only your selection
   (`window.getSelection()`) and hands that one string to the plugin.
3. **Resolve** (`SelectedName.lua` → `Taxonomy.lua`): your selection is canonicalized
   against **GBIF** (free, no key) — a binomial is confirmed by exact match; a common
   name is normalised to its accepted species, with the full classification chain. GBIF
   is the gate, so a common name that looks binomial still resolves correctly.
4. **Keywording** (`Keywords.lua`) writes the result: flat `common` + `Latin`
   keywords, the full hierarchy, or both.

The whole resolve → keyword pipeline is pure and unit-tested, independent of the browser
helper that feeds it. The full mental model — the layers, the data flow, and a "where do
I change X?" table — is in [ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Building from source

Everything is driven by scripts at the repo root (macOS; on Windows use WSL
for the dev toolchain — Windows *end users* just download the release):

```
./release.sh       # ONE command: clean checkout -> signed, notarized, distributable zip
./install.sh       # one-shot: toolchain + Lens helper deps + build + install a copy into Lightroom
./dev-setup.sh     # just the pinned Lua 5.1 + LuaRocks toolchain (.lua-env)
./build.sh         # build output/dist/SpeciesTagger.lrplugin (+ zip + checksums)
```

Or the finer-grained [`just`](https://github.com/casey/just) recipes:

```
just check         # lint + test + build (run before pushing)
just lint          # luacheck src spec scripts
just test          # busted unit specs
just lens-test     # drive the real Lens helper against a fake Google (needs Chrome)
just build         # compose the bundle, version-stamp, zip + checksums
just install       # build + install a full plugin copy into ~/Documents/Lightroom Plugins (Add/Reload)
just release       # the one-command signed + notarized release (= ./release.sh)
```

There is no build step to memorise and **no AI in the loop**: `just check` is the
whole gate, and it's exactly what CI runs.

## Repository layout — authored vs. generated

*(Answering the reasonable question "is all that code in `node_modules` / `.deps`
ours?" — no. Here's every tree and who wrote it.)*

**Authored (this is the project):**

```
src/shared/                 pure, testable modules (name resolver, taxonomy, keywords, http)
src/SpeciesTagger.lrplugin/ the Lightroom glue (menus, settings, catalog writes)
scripts/lens/               the Google Lens browser helper (lens-search.js, overlay-inject.js, tests)
spec/                       unit specs (busted) + GBIF fixtures for offline tests
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

- It's only as good as **what you can find in Lens** — clear, well-framed subjects do
  best, and Lens returns many related species, so you pick the right one.
- It tags what **you** highlight: subspecies and look-alikes are your call, and GBIF
  resolves to species/genus. It's a fast assist, not a taxonomist.
- The Lens step is **best-effort** (a consumer Google surface, in your own browser).
  Run from a residential network; solve any check yourself.

## Scope & responsible use

Species Tagger is designed to **work within Google's Terms of Service**, because it
doesn't do the thing those terms restrict — automated access to, and extraction of,
Google's results:

- **You read, you choose.** Recognition runs in a **visible** Chrome window showing
  Google's real results page. The plugin does **not** scrape or read those results —
  **you** highlight the species name, and it uses only that selection.
- **You initiate the search.** The plugin loads Lens and you add keywords / press
  Search; there's no hidden or high-volume querying.
- **No account, no key, no third-party host, no bulk access.** An anonymous session on
  your own machine; the image goes only to Google Lens, and only the name you
  highlighted becomes keywords (resolved through the open **GBIF** API).

It's a personal, one-photo-at-a-time tool; you remain responsible for your own use of
third-party services.

## Contributing

Issues and PRs welcome. [Building from source](#building-from-source) above is the whole
setup — `just check` (lint + tests + build) is the entire gate. For the mental model —
the layers, the data flow, and a "where do I change X?" table — see
[ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License

[MIT](LICENSE) © 2026 Yuval Oren
