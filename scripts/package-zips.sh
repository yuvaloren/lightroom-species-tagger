#!/usr/bin/env bash
# package-zips.sh — package the composed SpeciesTagger.lrplugin into the three
# release zips + checksums.txt. The SINGLE source of packaging truth, shared by
# build/build.lua (dev/CI zips) and scripts/sign-macos.sh (signed release zips),
# so the two paths can never drift.
#
#   bash scripts/package-zips.sh <version-label>
#
# Reads output/dist/SpeciesTagger.lrplugin — composed, and (on the release path)
# already signed. Pruning COPIES after signing is safe: every Mach-O is signed
# individually and a folder has no bundle-level signature. Produces in output/dist:
#
#   SpeciesTagger-<ver>-mac.zip   darwin Node runtime(s) only + darwin native prebuilds
#   SpeciesTagger-<ver>-win.zip   node.exe only + win32 native prebuilds
#   SpeciesTagger-<ver>-all.zip   both runtimes — single-package channels
#                                 (e.g. Adobe Exchange) take this one
#   checksums.txt                 sha256 for every zip produced
#
# Every zip keeps exactly ONE top-level entry, SpeciesTagger.lrplugin/ (the folder
# name Lightroom needs), so macOS Archive Utility extracts it flat. Explorer's
# Extract-All wraps extraction in a folder named after the zip — which is why the
# basenames are the clean SpeciesTagger-<ver>-<os>, not the old plugin-lookalike
# SpeciesTagger.lrplugin-<ver>. Install instructions live in the GitHub README, not
# in the zips (matching Adobe Exchange packaging norms — packages carry no readme).
#
# A -mac/-win variant whose runtime isn't in the bundle is SKIPPED with a warning
# (single-platform dev composes stay usable); CI's smoke check asserts all three
# exist, so a release can never silently drop one.
set -euo pipefail
cd "$(dirname "$0")/.." # repo root
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mpackage-zips:\033[0m %s\n' "$*" >&2; exit 1; }

VERSION="${1:-}"
[ -n "$VERSION" ] || die "usage: package-zips.sh <version-label>"
command -v zip >/dev/null 2>&1 || die "zip is required to package artifacts"

DIST="output/dist"
BUNDLE="$DIST/SpeciesTagger.lrplugin"
[ -d "$BUNDLE" ] || die "no bundle at $BUNDLE — compose first (bash build.sh --no-zip)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Native prebuilds for platforms the plugin never runs on are dead weight in every
# variant (it only ever runs under Node on macOS or Windows).
prune_prebuilds() { # $1 = tree, $2.. = prebuild platform prefixes to drop
	local tree="$1"; shift
	local plat
	for plat in "$@"; do
		find "$tree" -type d -path "*/prebuilds/${plat}-*" -exec rm -rf {} + 2>/dev/null || true
	done
}

ZIPS=()
make_zip() { # $1 = variant: mac | win | all
	local variant="$1"
	local zipname="SpeciesTagger-$VERSION-$variant.zip"
	local work="$TMP/$variant"
	local tree="$work/SpeciesTagger.lrplugin"
	mkdir -p "$work"
	cp -R "$BUNDLE" "$tree"
	prune_prebuilds "$tree" ios android linux
	case "$variant" in
		mac)
			rm -rf "$tree/node/win-"*
			prune_prebuilds "$tree" win32
			if ! compgen -G "$tree/node/darwin-*/node" >/dev/null; then
				say "WARNING: bundle has no darwin Node — skipping $zipname"
				return 0
			fi
			;;
		win)
			rm -rf "$tree/node/darwin-"*
			prune_prebuilds "$tree" darwin
			if ! compgen -G "$tree/node/win-*/node.exe" >/dev/null; then
				say "WARNING: bundle has no node.exe — skipping $zipname"
				return 0
			fi
			;;
		all) : ;; # ships whatever the bundle carries
		*) die "unknown variant: $variant" ;;
	esac
	( cd "$work" && zip -qr "$zipname" "SpeciesTagger.lrplugin" )
	mv "$work/$zipname" "$DIST/$zipname"
	ZIPS+=( "$zipname" )
	say "zipped $zipname"
}

rm -f "$DIST"/*.zip "$DIST/checksums.txt"
make_zip mac
make_zip win
make_zip all
[ "${#ZIPS[@]}" -gt 0 ] || die "no zips were produced"

if command -v shasum >/dev/null 2>&1; then SHA="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"
else SHA=""; fi
if [ -n "$SHA" ]; then
	( cd "$DIST" && $SHA "${ZIPS[@]}" > checksums.txt )
	say "wrote checksums.txt"
else
	say "note: no shasum/sha256sum found — skipped checksums.txt"
fi
