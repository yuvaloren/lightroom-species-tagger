# justfile — task runner for lightroom-species-tagger.
# `just` is a thin convenience layer over build/build.lua and the test/lint tools.
# CI does not depend on just (it calls lua/luarocks directly), so this is optional
# sugar for local development.
#
# Install just:  brew install just   (https://github.com/casey/just)

# Prefer the pinned .lua-env toolchain (created by `just setup`) over system Lua.
export PATH := justfile_directory() / ".lua-env" / "bin" + ":" + env_var("PATH")

# show the recipe list
default:
    @just --list

# one-shot machine bootstrap: Homebrew + lua/luarocks/just + dev rocks + deps
setup:
    bash ./dev-setup.sh

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

# static analysis
lint:
    luacheck src spec scripts

# run the unit tests
test: _deps
    busted

# run the tests with coverage, then print the summary
coverage: _deps
    busted --coverage
    luacov
    @tail -n 25 luacov.report.out

# the Go lens helper: unit suite (race detector on)
helper-test:
    make -C helper test

# drive the REAL compiled helper against a local fake Google (no network).
# Needs Chrome (LENS_CHROME to point at one). Not in `just check`.
helper-itest:
    make -C helper itest

# cross-compile every helper target + the universal mac binary (build needs this)
helper:
    make -C helper universal

# live smoke against REAL Google: full upload flow in a headed Chrome, the
# human's Tag press stood in for over the debug port. Run before releases on
# the Mac AND the Windows VM. Never in CI (network + ToS).
lens-live:
    cd helper && go test -tags live -count=1 -v -run TestLiveSmoke ./lens/

# compose the bundle into output/dist (version from VERSION / tag), zip + checksums
build: helper
    lua build/build.lua

# build, then install a full plugin copy into ~/Documents/Lightroom Plugins
# (override with LR_PLUGIN_DIR). First run: Add it in Plug-in Manager; after an
# update: click "Reload Plug-in".
install:
    lua build/build.lua --install

# remove the installed plugin copy (also remove it from Plug-in Manager if Added)
uninstall:
    lua build/build.lua --uninstall

# regenerate CHANGELOG.md from conventional-commit history (needs git-cliff)
changelog:
    git cliff --output CHANGELOG.md

# full local gate before pushing: lint + Lua tests + Go tests + build
check: lint test helper-test build

# Remove EVERYTHING generated — the output/ tree (bundle + pulled deps) + coverage
# artifacts. Plain rm by decision (Yuval, 2026-07-10): earlier mv-to-trash indirection
# was judged overengineered. Rare known blemish: a Finder window open inside output/
# can recreate .DS_Store mid-delete and fail one run ("Directory not empty") — rerun.
# (.output-trash-* sweeps leftovers from the retired mv-based recipe; gitignored.)
clean:
    rm -rf output .output-trash-*
    rm -f luacov.stats.out luacov.report.out
    make -C helper clean

# a full reset: also drop the pinned Lua toolchain + the Lens helper's node_modules
# (re-create them with ./dev-setup.sh and `cd scripts/lens && npm ci`)
clean-all: clean
    rm -rf .lua-env scripts/lens/node_modules

# Adobe Exchange submission package: signed SpeciesTagger.zxp (released -all zip
# payload + .mxi, ZXPSignCmd self-signed cert + timestamp). Defaults to the
# latest release tag; see docs/DISTRIBUTION.md.
exchange *ARGS:
    bash scripts/build-exchange.sh {{ARGS}}

# ONE command: clean checkout -> signed, notarized, distributable zip in output/dist/.
# Universal Node + Developer ID sign + notarize + package. Pass --allow-unsigned before the
# Developer ID exists; signing config via env or a gitignored scripts/signing.env (docs/SIGNING.md).
release *ARGS:
    bash release.sh {{ARGS}}
