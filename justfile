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
    luarocks install luacheck
    luarocks install busted
    luarocks install luacov
    lua build/build.lua --fetch-deps

# ensure the pulled dep (dkjson) is present; cheap once cached
_deps:
    @lua build/build.lua --fetch-deps

# static analysis
lint:
    luacheck src spec scripts

# run the unit + accuracy tests
test: _deps
    busted

# run the tests with coverage, then print the summary
coverage: _deps
    busted --coverage
    luacov
    @tail -n 25 luacov.report.out

# print the species-ID accuracy report over the offline fixture corpus
accuracy: _deps
    lua scripts/accuracy.lua

# record a new fixture from a real image (see scripts/record-fixture.lua)
record image *FLAGS: _deps
    lua scripts/record-fixture.lua {{image}} {{FLAGS}}

# capture REAL Google Lens output for the ground-truth corpus, for offline replay.
# Run on a residential network; needs `cd scripts/lens && npm i` + Chrome + curl.
capture *FLAGS:
    bash ./capture.sh {{FLAGS}}

# integration + regression tests for the interactive challenge-handling flow (fake
# local Google, no network). Needs Node + Chrome + `cd scripts/lens && npm i`. Not
# in `just check`.
lens-test:
    node scripts/lens/test/integration.test.js
    node scripts/lens/test/overlay-frame.test.js

# measure REAL Google Lens accuracy via the browser helper (writes nothing).
# Run on a residential network; needs `cd scripts/lens && npm i` + Chrome + curl.
live-accuracy *FLAGS: _deps
    lua scripts/live-accuracy.lua {{FLAGS}}

# compose dist/ bundle (version from VERSION / tag), zip + checksums
build:
    lua build/build.lua

# build, then symlink the bundle into the local Lightroom Modules folder
install:
    lua build/build.lua --install

# remove the Lightroom Modules symlink
uninstall:
    lua build/build.lua --uninstall

# regenerate CHANGELOG.md from conventional-commit history (needs git-cliff)
changelog:
    git cliff --output CHANGELOG.md

# full local gate before pushing: lint + test + build
check: lint test build

# remove build + coverage artifacts (keeps pulled deps; use clean-all to drop those)
clean:
    rm -rf dist
    rm -f luacov.stats.out luacov.report.out

# also drop the pulled-dependency cache
clean-all: clean
    rm -rf build/.deps
