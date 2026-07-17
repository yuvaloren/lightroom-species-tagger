# Architecture

A map of how this plugin is put together and *why* — read this before your first
change. For the how-to of running the gate and building, see the
[*Building from source*](../README.md#building-from-source) section of the README.

## The one idea that explains everything

**The plugin never reads Google's results — you do.** It opens Google Lens in your own
visible Chrome, you highlight the species name and press Tag, and it uses *only that
selection*. So the interesting logic is small and pure: take one highlighted string,
canonicalize it through GBIF, plan the keywords. All I/O is injected, so that logic is
unit-tested offline with no network and no Lightroom.

## The three layers

```
┌─────────────────────────────────────────────────────────────────────┐
│  src/SpeciesTagger.lrplugin/   Lightroom glue — the ONLY layer that   │
│                                imports Lr* and writes the catalog.    │
│    TagSpecies · SpeciesTaggerInfoProvider · Info · Version           │
├─────────────────────────────────────────────────────────────────────┤
│  src/shared/                   Pure, network-free, unit-tested core.  │
│    SelectedName · Taxonomy · Keywords · Config · Http (adapter) · Log │
├─────────────────────────────────────────────────────────────────────┤
│  helper/ (Go lens helper)     native CDP helper — opens Lens,       │
│                                shows the Tag bar, returns your pick.  │
│    lens-search.js · overlay-inject.js · test/                        │
└─────────────────────────────────────────────────────────────────────┘
```

Each layer changes for a different reason and is tested a different way. The pure core
holds the logic and has no dependency you can't fake in a spec. The Lightroom glue is
thin on purpose — if you're writing logic there, it probably belongs in `src/shared/`.
The lens helper is quarantined because it's the brittle part (it drives a real browser);
keeping it behind the `Http` seam means the rest of the system only ever sees "the string
the user highlighted."

## The flow (one photo)

```
 photo ─▶ downsized JPEG ─▶ Google Lens ─▶ YOU read + highlight ─▶ Tag
          (fresh render,     (visible          the species name    (button on
           EXIF/GPS stripped) Chrome window)    on Google's page     the page)
                                                                       │
        keywords ◀── plan (flat + hierarchy) ◀── canonical taxon ◀── GBIF resolve
```

1. **Render** — `TagSpecies.jpegBytes` asks Lightroom for a downsized JPEG (strips the
   original EXIF/GPS).
2. **Show Lens** — the lens helper (a static Go binary built from `helper/`,
   driven via `Http.lensAssistAdapter`)
   uploads the image the way the Lens website does and opens the results in a **visible**
   Chrome window, injecting a bottom bar (Tag / Skip / an "m of n" counter). One window
   is reused across photos (fresh tab each) and closed cleanly at the end.
3. **You choose** — you read Google's real page and highlight the species name. Pressing
   Tag records **only** `window.getSelection()` into a page global that the helper polls
   and returns. Nothing is scraped.
4. **Resolve** — `SelectedName.resolve` cleans the highlighted text and confirms it
   against **GBIF** (`Taxonomy.lua`): it tries the likely channel first (binomial vs.
   common) and falls back to the other, because the surface form is ambiguous — GBIF is
   the gate. Result: accepted Latin name, preferred common name, classification chain.
5. **Plan & apply keywords** — `Keywords.plan` turns the taxon into a provider-agnostic
   keyword plan (flat / hierarchy / both); `TagSpecies` walks it inside a
   `catalog:withWriteAccessDo` transaction. Skipped or unresolved photos are left
   untouched.

## The browser-helper contract

`Http.lensAssistAdapter{ helperPath, tabsPort }` returns `{ tag(imageFile, pos), close() }`.
`tag` runs the helper for one photo and blocks until you Tag a selection (returning the
string) or Skip / time out (returning `nil`). `close()` shuts the reused window down
cleanly. The helper communicates only through page globals it *polls* — no
`exposeFunction` — which is what lets it reconnect to the reused window across photos.
This is the entire seam between the pure core and the browser.

## Where to make a common change

| You want to… | Start in | And add a spec in |
|---|---|---|
| Change how a highlighted name is cleaned / which GBIF channel is tried | `src/shared/SelectedName.lua` | `spec/selectedname_spec.lua` |
| Adjust taxonomy resolution / GBIF handling | `src/shared/Taxonomy.lua` | `spec/taxonomy_spec.lua` |
| Change what keywords get written | `src/shared/Keywords.lua` | `spec/keywords_spec.lua` |
| Add/rename a setting | `src/shared/Config.lua` + `SpeciesTaggerInfoProvider.lua` | `spec/config_spec.lua` |
| Change the Lens window / overlay / reuse / shutdown | `scripts/lens/lens-search.js`, `overlay-inject.js` | `scripts/lens/test/integration.test.js` |
| Change catalog writes / the run loop / dialogs | `src/SpeciesTagger.lrplugin/TagSpecies.lua` | (glue — kept thin; logic goes to `src/shared/`) |

## Invariants worth preserving

- **The plugin never scrapes.** In the helper, read only the user's selection
  (`window.getSelection`) — never walk Google's DOM for results. This is the whole
  compliance story.
- **The pure layer stays pure.** No `import 'Lr*'`, no direct network in `src/shared/`
  logic — take a `deps` table instead. This keeps the tests offline and deterministic.
- **GBIF is the gate.** A highlighted string only becomes keywords once GBIF confirms it.
- **Fail soft.** A skip, timeout, or unresolved name leaves the photo untouched — never a
  wrong tag, never a crash.

## Build & release, in one breath

`build/build.lua` composes `src/` + the Lens helper into
`output/dist/SpeciesTagger.lrplugin`, stamps the version, and zips it with checksums. CI
runs the same `luacheck` + `busted` + build on every push; a `v*` tag additionally
publishes a GitHub Release. `just check` is the whole gate. Details in
[DISTRIBUTION.md](DISTRIBUTION.md).
