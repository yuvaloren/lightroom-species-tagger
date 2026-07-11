#!/usr/bin/env bash
# build-exchange.sh — build the SIGNED Adobe Exchange submission package:
# output/dist/SpeciesTagger.zxp = SpeciesTagger.lrplugin/ + SpeciesTagger.mxi,
# signed with ZXPSignCmd (self-signed cert, RFC-3161 timestamped).
#
#   just exchange        # or: bash scripts/build-exchange.sh [X.Y.Z]
#                        # default version: latest release tag
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
# + notarized). This script never re-composes or re-prunes. If the zip isn't in
# output/dist (a later dev build wiped it), it is fetched from the GitHub
# release for that version.
#
# ZXP signing (macOS only — ZXPSignCmd ships as a mac binary):
# - ZXPSignCmd 4.1.3 is fetched from Adobe-CEP/CEP-Resources and cached under
#   output/deps/zxpsigncmd/<version>/ (version-keyed — the Node-cache lesson:
#   an unkeyed cache silently serves stale binaries after a pin bump). 4.1.3
#   is the TSA-segfault fix (4.1.2 crashes on several timestamp servers).
# - The signing cert is SELF-SIGNED (Adobe's documented path for Exchange —
#   the portal re-encrypts uploads and ties them to the publisher's Adobe ID;
#   a CA cert is optional). Generated once into scripts/exchange-cert.p12 with
#   a random password in scripts/exchange-cert.pass (both gitignored) and
#   reused so the cert stays stable across versions. Override with
#   ZXP_CERT_P12 / ZXP_CERT_PASSWORD (e.g. in scripts/signing.env).
# - Timestamp: time.certum.pl first (the TSA that reliably works with
#   ZXPSignCmd; DigiCert's has a history of failures with it), Comodo as the
#   fallback.
#
# Adobe's naming rule: the .mxi basename must match the package basename and
# the mxi id attribute — hence SpeciesTagger.zxp + SpeciesTagger.mxi +
# id="SpeciesTagger". The package name is deliberately UNVERSIONED (the version
# lives inside the mxi), matching our evergreen installer asset names.
#
# Adobe's KnownIssue2024 checklist: no .DS_Store/__MACOSX in the package
# (stripped below — v0.3.0's -all zip shipped two .DS_Store; package-zips.sh
# now excludes them at the source) and no symlinks (zip -r materializes them).
set -euo pipefail
cd "$(dirname "$0")/.." # repo root
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mbuild-exchange:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only (ZXPSignCmd is a mac binary; hdiutil needed)"

REPO_SLUG="yuvaloren/lightroom-species-tagger"
DIST="output/dist"
BASE="SpeciesTagger" # mxi id == mxi basename == package basename (Adobe rule)
ZXPSIGN_VERSION="4.1.3"
ZXPSIGN_URL="https://raw.githubusercontent.com/Adobe-CEP/CEP-Resources/master/ZXPSignCMD/$ZXPSIGN_VERSION/macOS/ZXPSignCmd"
ZXPSIGN_CACHE="output/deps/zxpsigncmd/$ZXPSIGN_VERSION/ZXPSignCmd"

# 0. Optional signing config (same file the release pipeline uses).
if [ -f scripts/signing.env ]; then
	set -a
	# shellcheck source=/dev/null
	. scripts/signing.env
	set +a
fi

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

# ---- 2. ZXPSignCmd (version-keyed cache; fetched from Adobe's CEP-Resources) ----
# curl leaves no quarantine xattr, so the unsigned binary runs without the
# Sonoma Gatekeeper dance described in Adobe's 4.1.3 Readme.
if [ ! -x "$ZXPSIGN_CACHE" ]; then
	say "fetching ZXPSignCmd $ZXPSIGN_VERSION"
	mkdir -p "$(dirname "$ZXPSIGN_CACHE")"
	curl -fsSL -o "$ZXPSIGN_CACHE" "$ZXPSIGN_URL" || die "could not download ZXPSignCmd"
	chmod +x "$ZXPSIGN_CACHE"
fi

# ---- 3. signing cert (self-signed, generated once, reused across versions) -----
CERT="${ZXP_CERT_P12:-scripts/exchange-cert.p12}"
PASS="${ZXP_CERT_PASSWORD:-}"
if [ -z "$PASS" ] && [ -f scripts/exchange-cert.pass ]; then
	PASS="$(cat scripts/exchange-cert.pass)"
fi
if [ ! -f "$CERT" ]; then
	say "generating a self-signed signing cert ($CERT)"
	if [ -z "$PASS" ]; then
		PASS="$(openssl rand -hex 24)"
		printf '%s' "$PASS" > scripts/exchange-cert.pass
		chmod 600 scripts/exchange-cert.pass
	fi
	"$ZXPSIGN_CACHE" -selfSignedCert US CA "Yuval Oren" "Yuval Oren" "$PASS" "$CERT" >/dev/null \
		|| die "self-signed cert generation failed"
fi
[ -n "$PASS" ] || die "cert exists but no password — set ZXP_CERT_PASSWORD or restore scripts/exchange-cert.pass"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- 4. stage payload + mxi ------------------------------------------------------
say "extracting payload from $(basename "$ZIP_ALL")"
STAGE="$TMP/stage"
mkdir -p "$STAGE"
unzip -q "$ZIP_ALL" -d "$STAGE"
[ -d "$STAGE/$BASE.lrplugin" ] || die "unexpected zip layout — no top-level $BASE.lrplugin/"
find "$STAGE" \( -name '.DS_Store' -o -name '__MACOSX' \) -exec rm -rf {} + 2>/dev/null || true

# $modules resolves to the per-user Lightroom auto-load folder on both OSes
# (~/Library/Application Support/Adobe/Lightroom/Modules; %APPDATA%\Adobe\
# Lightroom\Modules). minVersion 11.4 = first LrC the CC-app install flow
# supports; the plugin itself runs on older LrC via manual install.
say "writing $BASE.mxi (version $VERSION)"
cat > "$STAGE/$BASE.mxi" <<XML
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

# ---- 5. sign -----------------------------------------------------------------------
OUT="$DIST/$BASE.zxp"
rm -f "$OUT" "$DIST/$BASE.zip" # drop any stale unsigned package from the zip era
say "signing with ZXPSignCmd (timestamped)"
if ! "$ZXPSIGN_CACHE" -sign "$STAGE" "$OUT" "$CERT" "$PASS" -tsa http://time.certum.pl/; then
	say "certum TSA failed — retrying with comodoca"
	"$ZXPSIGN_CACHE" -sign "$STAGE" "$OUT" "$CERT" "$PASS" -tsa http://timestamp.comodoca.com/rfc3161 \
		|| die "signing failed with both TSAs (TSAs go down regularly — retry later)"
fi

say "verifying signature"
"$ZXPSIGN_CACHE" -verify "$OUT" || die "ZXP verification failed"

say "built $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' ')) — upload via the Developer Distribution portal"
