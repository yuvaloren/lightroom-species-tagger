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

# static analysis: Lua (luacheck) + Go (gofmt/vet) + shell (shellcheck)
lint:
    luacheck src test build
    cd src/helper && test -z "$(gofmt -l .)" && go vet ./... && go vet -tags integration ./...
    shellcheck build/*.sh || true

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

# full local gate before pushing: lint + tests + build
check: lint test build

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

# ONE command: clean checkout -> signed, notarized, distributable zip in output/dist/.
# Developer ID sign + notarize + package. Pass --allow-unsigned before the Developer
# ID exists; signing config via env or a gitignored build/signing.env.
release *ARGS:
    bash build/release.sh {{ARGS}}
