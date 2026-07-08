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

# drive the REAL assist helper against a local fake Google (no network). Needs Node +
# Chrome + `cd scripts/lens && npm i`. Not in `just check`.
lens-test:
    cd scripts/lens && npm test

# compose the bundle into output/dist (version from VERSION / tag), zip + checksums
build:
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

# full local gate before pushing: lint + test + build
check: lint test build

# Race-free delete: `mv` atomically renames output/ out of existence in ONE syscall — we
# never rmdir a live directory (which can fail "Directory not empty" if a watcher, e.g.
# Finder recreating .DS_Store, an IDE, or a sync daemon, adds a file between emptying and
# removing it). Then rm the uniquely-named copy, which nothing is watching.
# Remove EVERYTHING generated — the output/ tree (bundle + pulled deps) + coverage artifacts.
clean:
    if [ -e output ]; then mv output ".output-trash-$$" && rm -rf ".output-trash-$$"; fi
    rm -f luacov.stats.out luacov.report.out

# a full reset: also drop the pinned Lua toolchain + the Lens helper's node_modules
# (re-create them with ./dev-setup.sh and `cd scripts/lens && npm ci`)
clean-all: clean
    rm -rf .lua-env scripts/lens/node_modules
