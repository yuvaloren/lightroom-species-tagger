#!/usr/bin/env bash
# dev-setup.sh — one-shot developer bootstrap (macOS / Linux).
#
# Builds an isolated, pinned Lua 5.1.5 + LuaRocks toolchain in .lua-env/ (matching
# CI and the Lightroom runtime), then installs the dev rocks and pulls the pinned
# dkjson. Re-runnable; safe to run again.
#
# After this, either `source .lua-env/bin/activate` or use the `justfile` (which
# puts .lua-env/bin first on PATH automatically).
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
ENV_DIR="$ROOT/.lua-env"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- Homebrew + just + git-cliff (macOS convenience; skipped if already present)
if [[ "$(uname)" == "Darwin" ]]; then
	if ! command -v brew >/dev/null 2>&1; then
		say "Homebrew not found. Install it from https://brew.sh then re-run."; exit 1
	fi
	command -v just      >/dev/null 2>&1 || { say "installing just";      brew install just; }
	command -v git-cliff >/dev/null 2>&1 || { say "installing git-cliff"; brew install git-cliff; }
fi

# --- hererocks: builds a local Lua + LuaRocks without touching the system Lua.
# Resolve a runnable hererocks, tolerating PEP 668 "externally-managed" Python
# (Homebrew / recent Debian) where a plain `pip install` is refused. We isolate
# it in a throwaway venv under .lua-env/ rather than poking the system Python.
if command -v hererocks >/dev/null 2>&1; then
	HEREROCKS=(hererocks)
elif python3 -m hererocks --help >/dev/null 2>&1; then
	HEREROCKS=(python3 -m hererocks)
else
	say "installing hererocks into an isolated bootstrap venv"
	VENV="$ENV_DIR/.bootstrap-venv"
	[[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV"
	"$VENV/bin/python" -m pip install --quiet --upgrade pip
	"$VENV/bin/python" -m pip install --quiet hererocks
	HEREROCKS=("$VENV/bin/python" -m hererocks)
fi

if [[ ! -x "$ENV_DIR/bin/lua" ]]; then
	say "building pinned Lua 5.1.5 + LuaRocks in .lua-env/"
	# --no-readline keeps the build self-contained where readline headers are absent.
	"${HEREROCKS[@]}" "$ENV_DIR" -l 5.1 -r latest --no-readline
fi

export PATH="$ENV_DIR/bin:$PATH"

say "installing dev rocks (luafilesystem luacheck busted luacov)"
luarocks install luafilesystem
luarocks install luacheck
luarocks install busted
luarocks install luacov

say "pulling the pinned runtime dependency (dkjson)"
lua build/build.lua --fetch-deps

say "done. Use 'just <recipe>' (e.g. 'just check'), or 'source .lua-env/bin/activate'."
