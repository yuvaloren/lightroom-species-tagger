#!/usr/bin/env bash
# build.sh — build the SpeciesTagger.lrplugin bundle into output/dist/.
#
# Thin wrapper over build/build.lua that prefers the pinned .lua-env toolchain
# (created by ./dev-setup.sh) if present. `just build` does the same thing.
set -euo pipefail

cd "$(dirname "$0")"
[[ -x .lua-env/bin/lua ]] && export PATH="$PWD/.lua-env/bin:$PATH"
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

say "building the plugin bundle into output/dist/"
exec lua build/build.lua "$@"
