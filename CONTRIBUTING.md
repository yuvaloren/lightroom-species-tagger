# Contributing

Thanks for looking. This project is meant to be **easy to pick up, run, and ship
without any AI in the loop** — one command to set up, one command to gate a change,
one tag to release. If anything here is more than one obvious step, that's a bug.

## Set up in one command

macOS or Linux (on Windows, use WSL for the dev toolchain):

```
./install.sh
```

That bootstraps a pinned, isolated Lua 5.1 + LuaRocks toolchain in `.lua-env/`
(nothing touches your system Lua), installs the dev rocks, pulls the one runtime dep
(`dkjson`), installs the Lens helper's Node deps, builds the bundle, and symlinks it
into your Lightroom `Modules/` folder. Re-runnable. `./install.sh --uninstall`
removes the symlink.

Just the toolchain, no Lightroom symlink? `./dev-setup.sh`.

## The gate — run this before every push

```
just check          # = lint + test + build. Exactly what CI runs.
```

Broken down:

```
just lint           # luacheck src spec scripts   (0 warnings is the standard)
just test           # busted: unit specs + the offline accuracy regression
just accuracy       # the accuracy table (recall / top-1 / genus / family / false+)
just build          # compose output/dist/, version-stamp, zip + checksums
```

The Google Lens browser helper has its own tests (they drive the **real** helper
against a local fake "Google" — no network, no Google), kept separate because they
need Node + Chrome:

```
just lens-test      # node scripts/lens/test/*.test.js  (needs Google Chrome)
```

No `just`? Every recipe is a thin wrapper over `busted`, `luacheck`, and
`lua build/build.lua` — run those directly.

## How it's laid out

```
src/shared/                 pure, network-free, unit-tested modules — the real logic
src/SpeciesTagger.lrplugin/ the thin Lightroom glue (menus, settings, catalog writes)
scripts/lens/               the Google Lens browser helper (Node) + its tests
scripts/*.lua               dev tooling (accuracy, corpus builders, live-accuracy, record-fixture)
spec/                       unit specs + the accuracy harness + the labelled fixture corpus
build/build.lua             composes/stamps/zips the .lrplugin (no framework)
output/                     ← everything GENERATED (bundle + pulled deps); git-ignored; `just clean` wipes it
```

The design rule that makes this testable: **all I/O is injected.** The pure modules
never call the network or Lightroom directly — they take a `deps` table (an `http`
adapter, a `resolve` function, a `lensSearch` function). In Lightroom those are backed
by `LrHttp` and the Node helper; in tests they're backed by recorded fixtures. That's
why the accuracy suite is fully offline and deterministic.

Recognition sits behind a one-module **provider seam**
(`src/shared/Providers.lua`); today the only provider is Google Lens, but the
parser → GBIF → scorer pipeline downstream doesn't know or care what produced the
observations.

## Making a change

1. Write the change in `src/shared/` (logic) or `src/SpeciesTagger.lrplugin/` (glue).
2. Add/adjust a spec in `spec/`. Pure functions get white-box tests via the module's
   `_test` table.
3. `just check` must be green (lint + tests + accuracy + build).
4. If you touched scoring or parsing, sanity-check real behaviour with
   `just live-accuracy -- --sweep` (see [docs/SCORING.md](docs/SCORING.md)).

### Growing the accuracy corpus

The corpus is open and reproducible — no personal data. Add cases from either source:

```
lua scripts/record-fixture.lua path/to/photo.jpg      # real Lens + GBIF fixture from one photo
lua scripts/build-inat-corpus.lua --n 40              # a batch from open iNaturalist data
```

Each prints a manifest stub to paste into `spec/fixtures/manifest.lua`; fill in the
`expected` ground truth. The GBIF responses are real captures; the bundled Lens
blobs are *representative* (see the note in the README).

## Conventions

- **Lua:** every module `return`s its table; no globals. `luacheck` is clean (see
  `.luacheckrc`). Comments explain *why*, not *what*.
- **Tabs** for indentation in Lua (match the surrounding files).
- **Pure where possible:** if logic can avoid `import`/network, it belongs in
  `src/shared/` with a spec.
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, …). `CHANGELOG.md` is generated from them by
  `git cliff` (`just changelog`).

## Releasing

The build stamps the version from a git tag, and CI publishes the release:

```
1. Bump the VERSION file and add a matching "## [X.Y.Z]" section to CHANGELOG.md.
2. git tag vX.Y.Z && git push --tags
```

On a `v*` tag, CI verifies the tag matches `VERSION` and `CHANGELOG.md`, builds the
self-contained `.lrplugin` (Lens helper deps bundled), writes checksums, and attaches
the zip to a GitHub Release. Distribution options are in
[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

## Privacy & scope for test data

Never commit real photos or live captures (they can carry personal EXIF or session
tokens) — the `.gitignore` already blocks `spec/fixtures/images/`,
`spec/fixtures/live/`, and `spec/fixtures/lens/raw/`. Keep the corpus impersonal:
open-licensed or synthetic data only.
