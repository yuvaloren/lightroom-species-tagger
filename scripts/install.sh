#!/usr/bin/env bash
# scripts/install.sh — build the bundle and symlink it into the local Lightroom
# Modules folder for live iteration. Pass --uninstall to remove the symlink.
#
#   scripts/install.sh                # build + symlink
#   scripts/install.sh --uninstall    # remove the symlink
#
# After the first install the symlink is picked up on Lightroom launch; after a
# rebuild use Plug-in Manager -> Reload. Editing a src/shared/ module requires a
# rebuild (the build copies shared modules into the bundle).
set -euo pipefail

cd "$(dirname "$0")/.."

# Prefer the pinned toolchain if present.
if [[ -x ".lua-env/bin/lua" ]]; then
	export PATH="$PWD/.lua-env/bin:$PATH"
fi

if [[ "${1:-}" == "--uninstall" ]]; then
	exec lua build/build.lua --uninstall
fi

exec lua build/build.lua --install
