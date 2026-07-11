#!/usr/bin/env bash
# build-exchange-zip.sh — build the Adobe Exchange submission package:
# output/dist/SpeciesTagger.zip = SpeciesTagger.lrplugin/ + SpeciesTagger.mxi.
#
#   bash scripts/build-exchange-zip.sh [X.Y.Z]     # default: latest release tag
#
# Adobe Exchange (the Creative Cloud marketplace) takes ONE package per listing
# — no per-OS selection — which is exactly what the -all zip exists for. Since
# CC desktop 5.8 (July 2022) the CC app installs Lightroom Classic plugins
# itself: the .mxi manifest maps SpeciesTagger.lrplugin to the $modules token —
# the same auto-load Modules folder our pkg/exe installers target — so the
# user's whole install is clicking "Install" in the CC app (plus a LrC restart).
# Reference:
# https://blog.developer.adobe.com/lightroom-classic-plugin-support-for-the-adobe-exchange-for-creative-cloud-14e4a0f690df
#
# Single source of packaging truth: the payload is extracted from the ALREADY
# RELEASED SpeciesTagger-<ver>-all.zip (binaries inside are Developer ID signed
# + notarized; the -all zip itself was a notarization submission). This script
# never re-composes or re-prunes. If the zip isn't in output/dist (a later dev
# build wiped it), it is fetched from the GitHub release for that version.
#
# Adobe's naming rule: the .mxi basename must match the package basename and
# the mxi id attribute — hence SpeciesTagger.zip + SpeciesTagger.mxi +
# id="SpeciesTagger". The package name is deliberately UNVERSIONED (the version
# lives inside the mxi), matching our evergreen installer asset names.
#
# ZXP: Exchange also accepts ZXPs (zip signed with ZXPSignCmd). We submit the
# plain zip first; if Adobe review asks for a ZXP, add that step here then.
set -euo pipefail
cd "$(dirname "$0")/.." # repo root
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mbuild-exchange-zip:\033[0m %s\n' "$*" >&2; exit 1; }

REPO_SLUG="yuvaloren/lightroom-species-tagger"
DIST="output/dist"
BASE="SpeciesTagger" # mxi id == mxi basename == package basename (Adobe rule)

# Default to the latest release tag — NOT the VERSION file, which is already
# reopened at the next -dev version the moment a release ships.
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
	TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null)" \
		|| die "no release tag found — pass the version explicitly"
	VERSION="${TAG#v}"
fi
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
	|| die "version '$VERSION' is not plain X.Y.Z — pass the released version explicitly"

command -v zip >/dev/null 2>&1 || die "zip is required"
command -v unzip >/dev/null 2>&1 || die "unzip is required"

# ---- 1. the released -all zip (local build output, else the GitHub release) ----
ZIP_ALL="$DIST/$BASE-$VERSION-all.zip"
if [ ! -f "$ZIP_ALL" ]; then
	command -v gh >/dev/null 2>&1 \
		|| die "no $ZIP_ALL and no gh to fetch it — run a release build or install gh"
	say "no local $(basename "$ZIP_ALL") — fetching from release v$VERSION"
	mkdir -p "$DIST"
	gh release download "v$VERSION" --repo "$REPO_SLUG" \
		--pattern "$BASE-$VERSION-all.zip" --dir "$DIST" \
		|| die "could not download $BASE-$VERSION-all.zip from release v$VERSION"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

say "extracting payload from $(basename "$ZIP_ALL")"
unzip -q "$ZIP_ALL" -d "$TMP"
[ -d "$TMP/$BASE.lrplugin" ] || die "unexpected zip layout — no top-level $BASE.lrplugin/"

# ---- 2. the mxi manifest --------------------------------------------------------
# $modules resolves to the per-user Lightroom auto-load folder on both OSes
# (~/Library/Application Support/Adobe/Lightroom/Modules; %APPDATA%\Adobe\
# Lightroom\Modules). minVersion 11.4 = first LrC the CC-app install flow
# supports; the plugin itself runs on older LrC via manual install.
say "writing $BASE.mxi (version $VERSION)"
cat > "$TMP/$BASE.mxi" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<macromedia-extension
	id="$BASE"
	name="Species Tagger"
	requires-restart="true"
	version="$VERSION">
	<author name="Yuval Oren"/>
	<description>
		<![CDATA[Identify the plants and animals in your photos and keyword them with common + scientific (Latin) names — with optional full taxonomy hierarchy. Uses Google Lens for identification and the GBIF taxonomy backbone for canonical names.]]>
	</description>
	<ui-access>
		<![CDATA[After restarting Lightroom Classic: File > Plug-in Extras > Identify and Tag Species… (quick start under Help > Plug-in Extras).]]>
	</ui-access>
	<license-agreement>
		<![CDATA[$(cat LICENSE)]]>
	</license-agreement>
	<products>
		<product name="LightroomClassic" version="11"/>
	</products>
	<files>
		<file source="$BASE.lrplugin"
			destination="\$modules"
			file-type="ordinary"
			products="LightroomClassic"
			minVersion="11.4" />
	</files>
</macromedia-extension>
XML

# ---- 3. package -------------------------------------------------------------------
OUT="$DIST/$BASE.zip"
rm -f "$OUT"
( cd "$TMP" && zip -qr "$BASE.zip" "$BASE.lrplugin" "$BASE.mxi" )
mv "$TMP/$BASE.zip" "$OUT"
say "built $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' ')) — upload this at exchange.adobe.com via the Developer Distribution portal"
