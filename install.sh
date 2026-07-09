#!/usr/bin/env bash
# install.sh — one-shot install: set up the toolchain, install the Google Lens
# helper's Node deps, build the bundle, and copy a full standalone plugin into a
# Lightroom Plugins folder to Add/Reload in Plug-in Manager. Re-runnable.
#
#   ./install.sh                # full install (toolchain + npm i + build + copy)
#   ./install.sh --uninstall    # remove the installed copy
#
# First time, Add the printed folder in Plug-in Manager; after re-running to update,
# click "Reload Plug-in" (the copy is refreshed in place). Override the install
# location with LR_PLUGIN_DIR.
set -euo pipefail

cd "$(dirname "$0")"
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --uninstall: remove the installed copy and exit.
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
		say "WARNING: npm not found — needed HERE (build machine) to bundle the Lens helper's"
		say "         deps into the plugin. Install Node/npm, then re-run. (End users need"
		say "         only Google Chrome; Node ships inside the built plugin.)"
	fi
fi

# 3. Build the bundle (bundles scripts/lens) and copy a full standalone plugin into
#    the Lightroom Plugins folder. build.lua --install prints the Add/Reload steps.
say "building the plugin and installing a full copy for Lightroom"
lua build/build.lua --install

say "done — follow the Plug-in Manager steps above. Recognition uses Google Lens"
say "(free, no key) and needs only Google Chrome installed (Node ships in the plugin)."
