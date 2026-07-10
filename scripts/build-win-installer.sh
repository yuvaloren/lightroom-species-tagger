#!/usr/bin/env bash
# build-win-installer.sh — build the Windows one-click installer:
# SpeciesTagger-win-setup.exe, compiled cross-platform with makensis
# (brew install makensis) so release.sh stays ONE local command.
#
#   bash scripts/build-win-installer.sh          # after the -win zip exists
#
# Single source of packaging truth: the payload is extracted from the ALREADY
# BUILT SpeciesTagger-<ver>-win.zip (win-pruned by package-zips.sh) — this
# script never re-implements pruning, so installer and zip can't drift.
#
# Signing: delegated to scripts/sign-win.sh (Azure Trusted Signing — currently
# a pluggable stub until the Azure account's identity validation completes; an
# unsigned setup.exe shows a one-time SmartScreen "More info > Run anyway").
#
# The asset name is deliberately UNVERSIONED (SpeciesTagger-win-setup.exe) so
# the wiki's evergreen link
#   .../releases/latest/download/SpeciesTagger-win-setup.exe
# always resolves. The version lives inside the exe's version resource.
set -euo pipefail
cd "$(dirname "$0")/.." # repo root
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mbuild-win-installer:\033[0m %s\n' "$*" >&2; exit 1; }

command -v makensis >/dev/null 2>&1 || die "makensis not found — brew install makensis"

DIST="output/dist"
OUT="$DIST/SpeciesTagger-win-setup.exe"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
	if [ -f VERSION ]; then VERSION="$(tr -d '[:space:]' < VERSION)"; else VERSION="dev"; fi
fi
ZIP_WIN="$DIST/SpeciesTagger-$VERSION-win.zip"
[ -f "$ZIP_WIN" ] || die "no $ZIP_WIN — package first (scripts/package-zips.sh runs inside sign-macos.sh / build.lua)"

# VIProductVersion demands numeric x.y.z.w — strip any -suffix; dev -> 0.0.0.0.
VIVERSION="$(printf '%s' "$VERSION" | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
if [ -n "$VIVERSION" ]; then VIVERSION="$VIVERSION.0"; else VIVERSION="0.0.0.0"; fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

say "extracting payload from $(basename "$ZIP_WIN")"
if command -v ditto >/dev/null 2>&1; then ditto -x -k "$ZIP_WIN" "$TMP"; else unzip -q "$ZIP_WIN" -d "$TMP"; fi
PAYLOAD="$TMP/SpeciesTagger.lrplugin"
[ -d "$PAYLOAD" ] || die "unexpected zip layout — no top-level SpeciesTagger.lrplugin/"
[ -f "$PAYLOAD/node/win-x64/node.exe" ] || die "payload has no win-x64 node.exe"

say "compiling the installer (makensis)"
rm -f "$OUT"
makensis -V2 \
	-DVERSION="$VERSION" \
	-DVIVERSION="$VIVERSION" \
	-DPAYLOAD="$PAYLOAD" \
	-DOUTFILE="$PWD/$OUT" \
	installer/win/SpeciesTagger.nsi

[ -f "$OUT" ] || die "makensis produced no $OUT"

bash scripts/sign-win.sh "$OUT"
say "built $OUT"
