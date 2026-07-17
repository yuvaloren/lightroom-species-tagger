# Contributing

Species Tagger is a Lightroom Classic plugin (Lua) plus a small native Google
Lens helper (Go). Everything is driven through `just` — you never call a build
script or a path directly.

## Prerequisites

- **just** — `brew install just` (the one thing that can't self-heal).
- Everything else — the pinned Lua 5.1 toolchain, LuaRocks, dkjson, and Go —
  is bootstrapped for you by `just setup`. Go and a C toolchain must exist
  (`brew install go`); `just setup` installs the rest.
- To run the plugin you also need **Google Chrome** and **Lightroom Classic**.

```sh
brew install just        # then everything else:
just setup
```

## The commands

| Command | What it does |
|---|---|
| `just build` | From scratch → the installable bundle + zips in `output/dist/`. Idempotent; bootstraps anything missing. |
| `just build clean` | Same, but wipes `output/` and the helper's build output first. |
| `just test` | Lua specs (busted) + Go unit tests. |
| `just itest` | Go integration suite — the real helper against a local fake Google (needs Chrome; `LENS_CHROME` to point at one). |
| `just install` | Build if needed, then install the plugin into Lightroom's auto-load folder. |
| `just uninstall` | Remove it. |
| `just lens-live` | Opt-in smoke against the REAL Google (headed Chrome, ~30s). Run before releases; never in CI. |
| `just lint` | luacheck + gofmt + go vet + shellcheck + staticcheck. |
| `just check` | The full local gate: lint + tests + build. Run this before pushing. |
| `just package` | Build the signed + notarized installers (`.pkg`/`.exe`), zips, and checksums into `output/dist/` — no release. Runs from any branch. |

Releases are cut by the maintainer only, via `just release` (which verifies
you're on `main`, clean, and synced with origin before it publishes) —
contributors never run it. `just package` is the build-only equivalent for
testing the install flow.

## Layout

```
src/plugin/     the Lightroom plugin (Lua) — ships as SpeciesTagger.lrplugin
src/helper/     the Go lens helper (CDP client, Chrome control, overlay)
test/plugin/    busted specs + GBIF fixtures for the Lua modules
build/          everything that builds, signs, packages, installs, releases
wiki/           the user-facing guide (generated pages live here)
```

Go unit and integration tests live *next to* the Go code as `_test.go` files —
that's the Go idiom, and the toolchain never compiles them into the shipped
binary, so no test code can reach a release. The Lua specs are the ones that
sit in a separate `test/` tree, since the plugin ships as source.

## Working on the code

- **The Go helper** (`src/helper/`): read the invariants in the header of
  `src/helper/lens/session.go` before touching the assist flow — no scraping,
  polled page globals, the window-reuse lifecycle, and the small-binary budget
  are all load-bearing and test-guarded.
- **The Lua plugin** (`src/plugin/`): catalog writes and async work go through
  the Lightroom SDK's task/catalog APIs — keep them there; the pure modules
  under `src/plugin/shared/` stay free of SDK calls so the specs can run
  headless.

Run `just check` before every push. CI runs the same gate plus the Go
integration suite on macOS, Windows, and Linux.
