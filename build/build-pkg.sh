#!/usr/bin/env bash
# build-pkg.sh — build the macOS one-click installer: SpeciesTagger-mac.pkg.
#
# The pkg installs SpeciesTagger.lrplugin into the CURRENT USER's Lightroom
# auto-load folder — ~/Library/Application Support/Adobe/Lightroom/Modules —
# so Lightroom Classic picks it up on next launch with ZERO Plug-in Manager
# steps. No admin password: the distribution enables ONLY the currentUserHome
# domain.
#
#   bash build/build-pkg.sh                # after sign-macos.sh has run
#   ALLOW_UNSIGNED=1 bash build/build-pkg.sh   # unsigned pkg (never distributable)
#
# Single source of packaging truth: the payload is extracted from the ALREADY
# BUILT SpeciesTagger-<ver>-mac.zip (signed, mac-pruned by package-zips.sh) —
# this script never re-implements pruning, so pkg and zip can't drift.
#
# Signing: the pkg is signed with a **Developer ID Installer** identity (NOT the
# Application identity used for the binaries inside). Set
# MACOS_INSTALLER_SIGN_IDENTITY in build/signing.env, or let this script
# auto-detect the single "Developer ID Installer" in the keychain. The signed
# pkg is notarized and — unlike the bare-binary zips — STAPLED, so even an
# offline first install is clean.
#
# The asset name is deliberately UNVERSIONED (SpeciesTagger-mac.pkg) so the
# wiki's evergreen link
#   github.com/yuvaloren/lightroom-species-tagger/releases/latest/download/SpeciesTagger-mac.pkg
# always resolves. The version lives inside the pkg metadata.
set -euo pipefail
cd "$(dirname "$0")/.." # repo root
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mbuild-pkg:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only (needs pkgbuild/productbuild)"

PKG_ID="com.github.yuvaloren.lightroom-species-tagger"
DIST="output/dist"
OUT="$DIST/SpeciesTagger-mac.pkg"

# ---- version (same resolution as sign-macos.sh) ------------------------------
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
	if [ -f VERSION ]; then VERSION="$(tr -d '[:space:]' < VERSION)"; else VERSION="dev"; fi
fi
ZIP_MAC="$DIST/SpeciesTagger-$VERSION-mac.zip"
[ -f "$ZIP_MAC" ] || die "no $ZIP_MAC — run build/sign-macos.sh first (the pkg payload comes from the signed mac zip)"

ALLOW_UNSIGNED="${ALLOW_UNSIGNED:-0}"

# ---- signing identity ---------------------------------------------------------
# ALLOW_UNSIGNED=1 means an explicitly UNSIGNED build: never sign, never
# notarize — even if a Developer ID Installer identity happens to be in the
# keychain. (Auto-detecting it here would sign the pkg and then require notary
# credentials, defeating the whole point of --allow-unsigned.)
IDENTITY="${MACOS_INSTALLER_SIGN_IDENTITY:-}"
if [ "$ALLOW_UNSIGNED" = "1" ]; then
	IDENTITY=""
elif [ -z "$IDENTITY" ]; then
	IDENTITY="$(security find-identity -v -p basic 2>/dev/null \
		| grep -Eo '"Developer ID Installer: [^"]*"' | head -1 | tr -d '"')" || true
	[ -n "$IDENTITY" ] || die "no Developer ID Installer identity found — set MACOS_INSTALLER_SIGN_IDENTITY or pass ALLOW_UNSIGNED=1 (never distributable)"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- 1. payload from the signed mac zip ---------------------------------------
say "extracting payload from $(basename "$ZIP_MAC")"
mkdir -p "$TMP/root"
ditto -x -k "$ZIP_MAC" "$TMP/root"
[ -d "$TMP/root/SpeciesTagger.lrplugin" ] || die "unexpected zip layout — no top-level SpeciesTagger.lrplugin/"

# ---- 2. component pkg ----------------------------------------------------------
# Analyze, then force the component non-relocatable: Installer must always place
# it at the Modules path, never "find" a copy elsewhere and update that instead.
# Clean upgrade: a pkg OVERLAYS files and never removes paths absent from the
# new payload -- a <=0.3.x install carries node/ (~200 MB) + lens/ (~29 MB)
# that would otherwise survive every upgrade. The preinstall removes the
# previous plugin dir wholesale; it holds no user data (the Chrome profile
# lives in ~/.cache/speciestagger-lens, keywords live in the LR catalog).
mkdir -p "$TMP/scripts"
cat > "$TMP/scripts/preinstall" <<'SH'
#!/bin/sh
# $2 = install location (~/Library/Application Support/Adobe/Lightroom/Modules
# under the currentUserHome domain). Never rm blind on an empty $2.
[ -n "$2" ] && rm -rf "$2/SpeciesTagger.lrplugin"
exit 0
SH
chmod +x "$TMP/scripts/preinstall"

# An install must always ENABLE the plug-in: Lightroom remembers a disabled
# plug-in (by id AND by path) in its CC7 defaults and would otherwise keep the
# fresh install disabled (the wiki used to document this as a gotcha to fix by
# hand). The lens helper owns the prefs surgery (`enable-installed` — shared
# with build.lua --install and the NSIS exe); it goes through defaults(1), and
# this script runs as the installing user (currentUserHome domain), so the
# right per-user prefs are edited. Best-effort: never fail the install.
cat > "$TMP/scripts/postinstall" <<'SH'
#!/bin/sh
[ -n "$2" ] || exit 0
P="$2/SpeciesTagger.lrplugin"
for key in darwin-universal darwin-arm64 darwin-x64; do
	H="$P/helper/$key/lens-helper"
	if [ -x "$H" ]; then
		"$H" enable-installed "$P" || true
		break
	fi
done
exit 0
SH
chmod +x "$TMP/scripts/postinstall"

pkgbuild --analyze --root "$TMP/root" "$TMP/component.plist" >/dev/null
/usr/bin/python3 - "$TMP/component.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, 'rb') as f: comps = plistlib.load(f)
for c in comps: c['BundleIsRelocatable'] = False
with open(p, 'wb') as f: plistlib.dump(comps, f)
PY
say "building component pkg (install-location: ~/Library/Application Support/Adobe/Lightroom/Modules)"
pkgbuild --root "$TMP/root" \
	--component-plist "$TMP/component.plist" \
	--scripts "$TMP/scripts" \
	--identifier "$PKG_ID" \
	--version "$VERSION" \
	--install-location "/Library/Application Support/Adobe/Lightroom/Modules" \
	"$TMP/component.pkg" >/dev/null

# ---- 3. distribution (currentUserHome ONLY -> no admin prompt) ------------------
RES="$TMP/resources"
mkdir -p "$RES"
cp build/installer/mac/resources/welcome.html build/installer/mac/resources/conclusion.html "$RES/"
# The Plug-in Extras menu screenshot is embedded when present (captured for the wiki).
if [ -f wiki/images/plugin-extras-menu.png ]; then
	cp wiki/images/plugin-extras-menu.png "$RES/"
fi

cat > "$TMP/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
	<title>Species Tagger for Lightroom Classic</title>
	<welcome file="welcome.html"/>
	<conclusion file="conclusion.html"/>
	<options customize="never" require-scripts="true" hostArchitectures="arm64,x86_64"/>
	<domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="false"/>
	<pkg-ref id="$PKG_ID" version="$VERSION">component.pkg</pkg-ref>
	<choices-outline>
		<line choice="default">
			<line choice="$PKG_ID"/>
		</line>
	</choices-outline>
	<choice id="default"/>
	<choice id="$PKG_ID" visible="false">
		<pkg-ref id="$PKG_ID"/>
	</choice>
</installer-gui-script>
XML

SIGN_ARGS=()
[ -n "$IDENTITY" ] && SIGN_ARGS=(--sign "$IDENTITY" --timestamp)
say "productbuild ${IDENTITY:+(signed: $IDENTITY)}"
productbuild --distribution "$TMP/distribution.xml" \
	--resources "$RES" \
	--package-path "$TMP" \
	${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
	"$TMP/SpeciesTagger-mac.pkg" >/dev/null

# ---- 4. notarize + staple -------------------------------------------------------
if [ -n "$IDENTITY" ]; then
	notary_args=()
	if [ -n "${NOTARY_KEY_P8_BASE64:-}" ]; then
		printf '%s' "$NOTARY_KEY_P8_BASE64" | base64 --decode > "$TMP/AuthKey.p8"
		notary_args=(--key "$TMP/AuthKey.p8" \
			--key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID required}" \
			--issuer "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID required}")
	elif [ -n "${NOTARY_PROFILE:-}" ]; then
		notary_args=(--keychain-profile "$NOTARY_PROFILE")
	else
		die "no notary credentials — set NOTARY_PROFILE or NOTARY_KEY_* (see this script's header)"
	fi
	say "notarizing the pkg (this can take a few minutes)…"
	xcrun notarytool submit "$TMP/SpeciesTagger-mac.pkg" "${notary_args[@]}" --wait 2>&1 | tee "$TMP/notary.out" || true
	nstatus="$( grep -E '^[[:space:]]*status:' "$TMP/notary.out" | tail -1 | awk '{print $NF}' )"
	if [ "$nstatus" != "Accepted" ]; then
		nid="$( grep -Eo 'id: [0-9a-fA-F-]{36}' "$TMP/notary.out" | head -1 | awk '{print $2}' )"
		[ -n "$nid" ] && { say "notarization $nstatus — Apple's issues:"; xcrun notarytool log "$nid" "${notary_args[@]}" 2>&1 | head -60; }
		die "pkg notarization was not Accepted (status: ${nstatus:-unknown})"
	fi
	say "stapling the notarization ticket"
	xcrun stapler staple "$TMP/SpeciesTagger-mac.pkg" >/dev/null
	xcrun stapler validate "$TMP/SpeciesTagger-mac.pkg" >/dev/null || die "staple validation failed"
fi

mv "$TMP/SpeciesTagger-mac.pkg" "$OUT"
say "built $OUT ${IDENTITY:+(signed, notarized, stapled)}"
