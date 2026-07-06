#!/usr/bin/env bash
# install.sh — one-shot install: set up the toolchain, install the Google Lens
# helper's Node deps, build the bundle, and symlink it into the local Lightroom
# Modules folder. Re-runnable.
#
#   ./install.sh                # full install (toolchain + npm i + build + symlink)
#   ./install.sh --uninstall    # remove the Lightroom symlink
#
# After the first install the symlink is picked up on Lightroom launch; after a
# rebuild use Plug-in Manager -> Reload. Editing a src/shared/ module requires a
# rebuild (the build copies shared modules into the bundle).
set -euo pipefail

cd "$(dirname "$0")"
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --uninstall: just remove the symlink and exit.
if [[ "${1:-}" == "--uninstall" ]]; then
	[[ -x ".lua-env/bin/lua" ]] && export PATH="$PWD/.lua-env/bin:$PATH"
	exec lua build/build.lua --uninstall
fi

# 1. Lua toolchain (pinned Lua 5.1 + LuaRocks + luafilesystem/dkjson). Bootstrap it
#    if the isolated env isn't there yet; otherwise just put it on PATH.
if [[ ! -x ".lua-env/bin/lua" ]]; then
	say "setting up the pinned Lua toolchain (.lua-env) via ./dev-setup.sh"
	bash "$(dirname "$0")/dev-setup.sh"
fi
export PATH="$PWD/.lua-env/bin:$PATH"

# 2. Google Lens helper deps (puppeteer-core; drives your installed Google Chrome).
#    Required for recognition to work — but non-fatal here so the bundle still builds.
if [[ -f scripts/lens/package.json ]]; then
	if command -v npm >/dev/null 2>&1; then
		say "installing the Google Lens helper deps (cd scripts/lens && npm i)"
		( cd scripts/lens && npm i ) || say "WARNING: 'npm i' failed — recognition won't work until it succeeds. Re-run after fixing Node/npm."
	else
		say "WARNING: npm not found — skipping the Google Lens helper deps."
		say "         Recognition needs Node.js + Google Chrome; install Node, then re-run."
	fi
fi

# 3. Build the bundle (bundles scripts/lens) and symlink it into Lightroom Modules.
say "building the plugin and symlinking it into the Lightroom Modules folder"
lua build/build.lua --install

say "done. In Lightroom Classic: Plug-in Manager picks it up on launch (or use Reload"
say "after a rebuild). Recognition uses Google Lens (free, no key) and needs Node.js +"
say "Google Chrome installed; set the node path in the plugin settings if it isn't auto-found."
