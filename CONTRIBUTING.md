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
(`dkjson`), installs the Lens helper's Node deps, builds the bundle, and installs a
full standalone plugin copy into `~/Documents/Lightroom Plugins/` (override with
`LR_PLUGIN_DIR`). Re-runnable. The first time, **Add** the printed folder in
Lightroom's Plug-in Manager; after re-running `./install.sh` to update, click
**Reload Plug-in** (or restart Lightroom — a newly *added* module file only registers
on a full re-add/restart). `./install.sh --uninstall` removes the installed copy.

Just the toolchain, no Lightroom install? `./dev-setup.sh`.

## The gate — run this before every push

```
just check          # = lint + test + build. Exactly what CI runs.
```

Broken down:

```
just lint           # luacheck src spec scripts   (0 warnings is the standard)
just test           # busted: the offline unit specs
just build          # compose output/dist/, version-stamp, zip + checksums
```

The Google Lens browser helper has its own test (it drives the **real** helper against
a local fake "Google" — no network, no Google), kept separate because it needs Node +
Chrome:

```
just lens-test      # cd scripts/lens && npm test   (needs Google Chrome)
```

No `just`? Every recipe is a thin wrapper over `busted`, `luacheck`, and
`lua build/build.lua` — run those directly.

## How it's laid out

```
src/shared/                 pure, network-free, unit-tested modules — the real logic
src/SpeciesTagger.lrplugin/ the thin Lightroom glue (menus, settings, catalog writes)
scripts/lens/               the Google Lens browser helper (Node) + its test
spec/                       unit specs + GBIF fixtures for the offline tests
build/build.lua             composes/stamps/zips the .lrplugin (no framework)
output/                     ← everything GENERATED (bundle + pulled deps); git-ignored; `just clean` wipes it
```

The design rule that makes this testable: **all I/O is injected.** The pure modules
never call the network or Lightroom directly — they take a `deps` table (an `http`
adapter, a `cache`). In Lightroom those are backed by `LrHttp`; in tests they're backed
by recorded GBIF fixtures. That's why the whole resolve → keyword suite is offline and
deterministic. The one thing the plugin does NOT do is read Google's results — the user
highlights the species and the browser helper returns only that selection. For the full
mental model see **[ARCHITECTURE.md](ARCHITECTURE.md)**.

### Working on the pure core (no Lightroom needed)

**You do not need Lightroom to work on the interesting half.** Everything in
`src/shared/` — the name resolver (`SelectedName`), taxonomy resolver (`Taxonomy`),
keyword planner (`Keywords`) — is pure and runs fully offline. `just check` exercises it
with zero Lightroom involved. If your change is logic, it belongs here, with a spec.

### Working on the Lightroom glue

Only the files in `src/SpeciesTagger.lrplugin/` need Lightroom, and exercising them
needs a licensed **Lightroom Classic** (there's no headless Lightroom). A few things
that aren't obvious the first time:

- **The entry-point map.** `Info.lua` registers the menu item; `SpeciesTaggerMenuItem.lua`
  wraps the work in `LrTasks.startAsyncTask` → `LrFunctionContext.callWithContext` →
  `LrTasks.pcall` (so a stray error can't wedge Lightroom). `TagSpecies.run` is the
  **only** code that writes the catalog — always inside a per-photo
  `catalog:withWriteAccessDo`, with `createKeyword(..., returnExisting=true)` so re-runs
  never duplicate keywords.
- **Keep logic out of the glue.** A decision belongs in a pure `src/shared/` module with
  a spec, not a `.lrplugin` file. The glue only renders, gathers input, writes the catalog.
- **Settings must bind to prefs.** A settings control needs `bind_to_object = prefs`
  (see `SpeciesTaggerInfoProvider.lua`) or it silently opens empty and never persists.
- **The dev loop.** `./install.sh` builds and installs; **Add** it once in Plug-in
  Manager, then **Reload Plug-in** after each rebuild — but restart Lightroom after
  adding a brand-new `.lua` module (Reload won't register a new file). Runtime logs go to
  Lightroom's `Documents/` logs folder.
- **The SDK reference.** <https://developer.adobe.com/lightroom-classic/> — the authority
  for the `Lr*` APIs.

## Making a change

1. Write the change in `src/shared/` (logic) or `src/SpeciesTagger.lrplugin/` (glue).
2. Add/adjust a spec in `spec/`. Pure functions get white-box tests via the module's
   `_test` table.
3. `just check` must be green (lint + tests + build).
4. If you touched the Lens helper, run `just lens-test` and — for the real browser flow —
   verify it once in Lightroom (the browser round-trip can't be exercised offline).

## Conventions

- **Lua:** every module `return`s its table; no globals. `luacheck` is clean (see
  `.luacheckrc`). Comments explain *why*, not *what*.
- **Tabs** for indentation in Lua (match the surrounding files).
- **The plugin never scrapes Google.** In the helper, read only the user's selection
  (`window.getSelection`) — never the results DOM. That's the compliance line.
- **Pure where possible:** if logic can avoid `import`/network, it belongs in
  `src/shared/` with a spec.
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, …). `CHANGELOG.md` is generated from them by
  `git cliff` (`just changelog`).

## Task playbooks (`.claude/skills/`)

Common recurring tasks have short step-by-step playbooks in
[`.claude/skills/`](.claude/skills/) — cutting a release, reviewing a PR, editing the
Lens helper, and changing the Lightroom glue. They're plain Markdown checklists (and
[Claude Code](https://claude.com/claude-code) skills if you use it).

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

Never commit real photos (they can carry personal EXIF) — the `.gitignore` blocks
`spec/fixtures/images/`. The committed GBIF fixtures under `spec/fixtures/gbif/` are
impersonal API responses. Keep any added test data open-licensed or synthetic.
