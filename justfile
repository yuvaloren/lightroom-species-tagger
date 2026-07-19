# justfile — the single task surface for lightroom-species-tagger.
# Everything (build, test, install, release) goes through `just`; the scripts
# under build/ are implementation detail you never call directly.
#
# Install just:  brew install just   (https://github.com/casey/just)

# Prefer the pinned .lua-env toolchain (created by `just setup`) over system Lua.
export PATH := justfile_directory() / ".lua-env" / "bin" + ":" + env_var("PATH")

# show the recipe list
default:
    @just --list

# one-shot machine bootstrap: Homebrew tools (go, just, git-cliff) + pinned
# Lua 5.1/LuaRocks + dev rocks + the pulled dep (dkjson). Idempotent.
setup:
    bash build/setup.sh

# install the Lua dev tooling, then pull the pinned runtime dep (dkjson)
deps:
    luarocks install luafilesystem
    luarocks install luacheck 1.2.0   # pinned: keep in lock-step with CI (the gate is 0 warnings)
    luarocks install busted
    luarocks install luacov
    lua build/build.lua --fetch-deps

# ensure the pulled dep (dkjson) is present; cheap once cached
_deps:
    @lua build/build.lua --fetch-deps

# ensure the pinned toolchain exists (idempotent) — makes `just build` work from
# a clean checkout in one command
_toolchain:
    @[ -x .lua-env/bin/lua ] || just setup

# static analysis: Lua (luacheck) + Go (gofmt/vet/staticcheck) + shell (shellcheck).
# Every gate here is HARD and matches CI — a green `just lint` locally must mean
# a green lint in CI. staticcheck is pinned in lock-step with .github/workflows/ci.yml.
lint:
    luacheck src test build
    cd src/helper && test -z "$(gofmt -l .)" && go vet ./... && go vet -tags integration ./...
    cd src/helper && go run honnef.co/go/tools/cmd/staticcheck@2026.1 ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.1 -tags integration ./...
    shellcheck -S warning build/*.sh

# run the unit tests (Lua specs + Go helper units)
test: _deps
    busted
    cd src/helper && go test -race ./...

# run the Lua tests with coverage, then print the summary
coverage: _deps
    busted --coverage
    luacov
    @tail -n 25 luacov.report.out

# drive the REAL compiled helper against a local fake Google (no network).
# Needs Chrome (LENS_CHROME to point at one). Not in `just check`.
helper-itest:
    cd src/helper && go test -tags integration -race -count=1 ./lens/

# live smoke against REAL Google: full upload flow in a headed Chrome, the
# human's Tag press stood in for over the debug port. Run before releases on
# the Mac AND the Windows VM. Never in CI (network + ToS).
lens-live:
    cd src/helper && go test -tags live -count=1 -v -run TestLiveSmoke ./lens/

# From a clean checkout to the installable bundle + zips in output/dist/, in ONE
# command: bootstrap the toolchain if missing, cross-compile the Go helper, and
# compose. Idempotent. `just build clean` wipes output/ first.
build target="": _toolchain
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{target}}" = "clean" ]; then just clean; fi
    lua build/build.lua

# build if needed, then install a full plugin copy into ~/Documents/Lightroom
# Plugins (override with LR_PLUGIN_DIR). First run: Add it in Plug-in Manager;
# after an update: click "Reload Plug-in".
install: _toolchain
    lua build/build.lua --install

# remove the installed plugin copy (also remove it from Plug-in Manager if Added)
uninstall:
    lua build/build.lua --uninstall

# regenerate CHANGELOG.md from conventional-commit history (needs git-cliff)
changelog:
    git cliff --output CHANGELOG.md

# offline clustering-accuracy gate for burst detection: the REAL helper (hash
# mode) + the REAL Burst.lua over the labelled corpus in
# test/plugin/fixtures/burst-corpus. `just burst-accuracy --sweep` prints the
# threshold-tuning table HAMMING_THRESHOLD was chosen from.
burst-accuracy *ARGS: _deps
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p output/accuracy
    ( cd src/helper && go build -o ../../output/accuracy/lens-helper . )
    lua build/burst-accuracy.lua --helper output/accuracy/lens-helper {{ARGS}}

# guard: the lens helper must be EXECUTABLE in the composed bundle, in the zips,
# AND after `just install` (a plain byte-copy dropped the +x bit and the plugin
# could not run the helper). Depends on `build` so output/dist exists.
check-exec: build
    bash build/check-exec.sh

# guard: an install must always ENABLE the plug-in — Lightroom's remembered
# disabled state (by plugin id AND by path) is cleared for the copy being
# installed, and nothing else in the prefs is touched.
check-install-enables: build
    bash build/check-install-enables.sh

# full local gate before pushing: lint + tests + corpus accuracy + build + exec guard
check: lint test burst-accuracy build check-exec check-install-enables

# Remove EVERYTHING generated — the output/ tree (bundle + pulled deps), the Go
# helper's cross-compiled binaries, and coverage artifacts.
clean:
    rm -rf output .output-trash-* src/helper/dist
    rm -f luacov.stats.out luacov.report.out

# a full reset: also drop the pinned Lua toolchain (re-create with `just setup`)
clean-all: clean
    rm -rf .lua-env

# Adobe Exchange submission package: signed SpeciesTagger.zxp (released -all zip
# payload + .mxi, ZXPSignCmd self-signed cert + timestamp). Defaults to the
# latest release tag.
exchange *ARGS:
    bash build/build-exchange.sh {{ARGS}}

# Build the installable packages WITHOUT releasing: the signed + notarized
# macOS .pkg, the Windows .exe, the three zips, and checksums, into
# output/dist/. No version bump, no tag, no publish — and no on-main / clean /
# synced gate, so it runs from any branch. Use it to test the real install
# flow. Pass --allow-unsigned before the Developer ID exists.
package *ARGS:
    bash build/release.sh --no-publish {{ARGS}}

# THE release (irreversible once it pushes the tag): pre-flight VERIFIES you are
# on main, clean, and synced with origin, then cuts + Developer ID signs +
# notarizes + publishes vX.Y.Z and syncs the wiki. `just package` is the
# build-only dry run. Signing config via env or a gitignored build/signing.env.
release *ARGS:
    bash build/release.sh {{ARGS}}
