#!/usr/bin/env bash
# check-exec.sh — guard the one thing that makes the plugin able to RUN its
# helper: the macOS/Linux helper binary must be EXECUTABLE everywhere it lands.
#
# This exists because a regression shipped where `just install` copied the
# bundle with a plain byte-copy (write_file) that dropped the +x bit, so the
# installed helper was 0644 and the plugin could not exec it — every hash and
# every Tag failed instantly, the assist window never waited for the user, and
# the run blew through all photos. The build+zip path preserved +x; only the
# install path lost it, and nothing tested the install path.
#
# Checks (any failure exits 1):
#   1. the composed bundle in output/dist has an executable darwin helper
#   2. every zip stores the darwin helper with its +x bit
#   3. `lua build/build.lua --install` yields an EXECUTABLE installed helper
#      (the layer the regression lived in)
#
# Windows .exe helpers are intentionally NOT required to be +x (Windows keys
# executability off the extension, not the mode bit).
set -euo pipefail
cd "$(dirname "$0")/.."
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mcheck-exec:\033[0m %s\n' "$*" >&2; exit 1; }

DIST=output/dist
BUNDLE="$DIST/SpeciesTagger.lrplugin"
[ -d "$BUNDLE" ] || fail "no composed bundle at $BUNDLE — run 'lua build/build.lua' first"

# 1. composed bundle: every darwin helper is executable
say "bundle: darwin helper is executable"
found=0
while IFS= read -r bin; do
	found=1
	[ -x "$bin" ] || fail "composed helper is not executable: $bin ($(ls -l "$bin" | awk '{print $1}'))"
done < <(find "$BUNDLE/helper" -type f -name 'lens-helper')
[ "$found" = 1 ] || fail "no darwin lens-helper found under $BUNDLE/helper"

# 2. zips: the darwin helper keeps its +x bit (zipinfo's first column)
say "zips: darwin helper keeps +x"
for z in "$DIST"/SpeciesTagger-*-mac.zip "$DIST"/SpeciesTagger-*-all.zip; do
	[ -f "$z" ] || continue
	line="$(zipinfo "$z" 'SpeciesTagger.lrplugin/helper/darwin-universal/lens-helper' 2>/dev/null || true)"
	[ -n "$line" ] || fail "no darwin helper entry in $(basename "$z")"
	case "$line" in
		-*x*) : ;; # some execute bit set
		*) fail "$(basename "$z") stores the darwin helper without +x: $line" ;;
	esac
done

# 3. the install path: an actually-executable installed helper
say "install: 'lua build/build.lua --install' yields an executable helper"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
LR_PLUGIN_DIR="$tmp" lua build/build.lua --install >/dev/null 2>&1 \
	|| fail "install run failed (LR_PLUGIN_DIR=$tmp)"
inst=0
while IFS= read -r bin; do
	inst=1
	[ -x "$bin" ] || fail "INSTALLED helper is not executable: $bin ($(ls -l "$bin" | awk '{print $1}')) — the plugin cannot run it"
done < <(find "$tmp/SpeciesTagger.lrplugin/helper" -type f -name 'lens-helper')
[ "$inst" = 1 ] || fail "no darwin lens-helper found after install"

say "OK: helper is executable in the bundle, the zips, and after install"
