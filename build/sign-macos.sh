#!/usr/bin/env bash
# sign-macos.sh — turn a freshly composed SpeciesTagger.lrplugin into a signed,
# notarized release zip set for macOS.
#
# The plugin bundles one native binary: the Go lens helper at
# helper/darwin-universal/lens-helper (universal2, built by
# `lua build/build.lua (cross-compiles the helper)`). An unsigned binary that arrives quarantined
# (browser download + Finder unzip) is blocked by Gatekeeper on first run, so:
#   1. verify the bundled helper really is universal (arm64 + x86_64) — the
#      Makefile lipos it; this script never builds or fetches anything.
#   2. codesign every Mach-O in the bundle with a Developer ID identity +
#      hardened runtime + timestamp. Go binaries need NO entitlements (no JIT
#      — the old Node runtime needed allow-jit; that whole story is gone).
#   3. package the three per-platform zips via build/package-zips.sh
#      (SpeciesTagger-<version>-mac/-win/-all.zip + checksums.txt).
#   4. notarize the mac-containing zips (-mac and -all) with notarytool.
#      The -win zip ships no Mach-O, so it needs none. (NOTE: unlike the old
#      OpenJS-signed node.exe, lens-helper.exe is NOT Authenticode-signed
#      until Azure Trusted Signing lands — sign-win.sh remains the hook.)
#
# Run it AFTER building the helper and composing the bundle:
#   lua build/build.lua (cross-compiles the helper)
#   lua build/build.lua --no-zip
#   bash build/sign-macos.sh
#
# Signing/notarization need an Apple Developer ID (see this script's header). Until
# you have it, run with --allow-unsigned to package only (NOT distributable).
#
# macOS only (needs lipo / codesign / xcrun).
set -euo pipefail

cd "$(dirname "$0")/.." # repo root
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31msign-macos:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- options ----------------------------------------------------------------
ALLOW_UNSIGNED="${ALLOW_UNSIGNED:-0}"
VERSION_ARG=""
for a in "$@"; do
	case "$a" in
		--allow-unsigned) ALLOW_UNSIGNED=1 ;;
		--version=*) VERSION_ARG="${a#--version=}" ;;
		-h|--help) grep '^#' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
		*) die "unknown option: $a" ;;
	esac
done

[ "$(uname -s)" = "Darwin" ] || die "macOS only (needs lipo/codesign/xcrun) — got $(uname -s)"

DIST="output/dist"
BUNDLE="$DIST/SpeciesTagger.lrplugin"
HELPER_BIN="$BUNDLE/helper/darwin-universal/lens-helper"
[ -d "$BUNDLE" ] || die "no bundle at $BUNDLE — compose first: lua build/build.lua (cross-compiles the helper) && lua build/build.lua --no-zip"
[ -f "$HELPER_BIN" ] || die "expected the universal helper at $HELPER_BIN — compose with darwin-universal (the default)"

# ---- version (mirror build.lua's resolution) --------------------------------
resolve_version() {
	if [ -n "$VERSION_ARG" ]; then echo "${VERSION_ARG#v}"; return; fi
	if [ -n "${GITHUB_REF_NAME:-}" ] && printf '%s' "$GITHUB_REF_NAME" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+'; then
		echo "${GITHUB_REF_NAME#v}"; return
	fi
	if [ -f VERSION ]; then tr -d '[:space:]' < VERSION; return; fi
	echo "dev"
}
VERSION="$(resolve_version)"
ZIP_MAC="SpeciesTagger-$VERSION-mac.zip"
ZIP_ALL="SpeciesTagger-$VERSION-all.zip"

# ---- will we sign this run? -------------------------------------------------
DO_SIGN=1
if [ "$ALLOW_UNSIGNED" = "1" ] && [ -z "${MACOS_SIGN_IDENTITY:-}" ]; then DO_SIGN=0; fi
if [ "$DO_SIGN" = "1" ] && [ -z "${MACOS_SIGN_IDENTITY:-}" ]; then
	die "MACOS_SIGN_IDENTITY is required to sign (or pass --allow-unsigned to package only). See the sign-macos.sh header"
fi
say "helper $(du -h "$HELPER_BIN" | cut -f1 | tr -d ' ') · plugin $VERSION · sign=$DO_SIGN"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- 1. the helper must be universal (arm64 + x86_64) ------------------------
lipo -info "$HELPER_BIN"
lipo -info "$HELPER_BIN" 2>/dev/null | grep -q 'x86_64' || die "helper is not universal — run: lua build/build.lua (cross-compiles the helper)"
lipo -info "$HELPER_BIN" 2>/dev/null | grep -q 'arm64'  || die "helper is not universal — run: lua build/build.lua (cross-compiles the helper)"

# ---- 2. codesign every Mach-O (Developer ID + hardened runtime) --------------
# The Go helper is the only native code in the bundle today, but the find-all
# loop stays: if another binary ever sneaks in, Apple rejects an archive with
# ANY unsigned Mach-O — better to sign it than to be surprised at notary time.
if [ "$DO_SIGN" = "1" ]; then
	# CI: import the Developer ID cert from a base64 .p12 into a throwaway keychain.
	# Local: the identity is already in your login keychain, so this block is skipped.
	if [ -n "${MACOS_CERT_P12_BASE64:-}" ]; then
		KC="$TMP/build.keychain"
		KCPW="${MACOS_KEYCHAIN_PASSWORD:-$(uuidgen)}"
		say "importing signing certificate into a temporary keychain"
		security create-keychain -p "$KCPW" "$KC"
		security set-keychain-settings -lut 21600 "$KC"
		security unlock-keychain -p "$KCPW" "$KC"
		printf '%s' "$MACOS_CERT_P12_BASE64" | base64 --decode > "$TMP/cert.p12"
		security import "$TMP/cert.p12" -k "$KC" -P "${MACOS_CERT_PASSWORD:-}" -T /usr/bin/codesign
		security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null
		security list-keychains -d user -s "$KC" "$(security default-keychain -d user | xargs)"
	fi
	say "codesign every Mach-O in the bundle (Developer ID + hardened runtime + timestamp)"
	signed=0
	while IFS= read -r -d '' f; do
		if file "$f" 2>/dev/null | grep -q 'Mach-O'; then
			codesign --force --options runtime --timestamp --sign "$MACOS_SIGN_IDENTITY" "$f"
			signed=$(( signed + 1 ))
		fi
	done < <( find "$BUNDLE" -type f -print0 )
	say "signed $signed Mach-O binaries"
	codesign --verify --strict --verbose=2 "$HELPER_BIN"
fi

# ---- 3. package the three distributable zips + checksums ---------------------
# Shared with build.lua's zip step — build/package-zips.sh is the single source
# of packaging truth (per-platform pruning happens on COPIES; the signed bundle
# itself is untouched, and every Mach-O carries its own signature).
say "packaging the release zips (build/package-zips.sh)"
bash build/package-zips.sh "$VERSION"
[ -f "$DIST/$ZIP_MAC" ] || die "packaging produced no $ZIP_MAC — compose with darwin-universal (the default)"
[ -f "$DIST/$ZIP_ALL" ] || die "packaging produced no $ZIP_ALL"

# ---- 4. notarize the mac-containing zips -------------------------------------
# The -win zip ships no Mach-O, so only -mac and -all are submitted.
if [ "$DO_SIGN" = "1" ]; then
	notary_args=()
	if [ -n "${NOTARY_KEY_P8_BASE64:-}" ]; then
		printf '%s' "$NOTARY_KEY_P8_BASE64" | base64 --decode > "$TMP/AuthKey.p8"
		notary_args=(--key "$TMP/AuthKey.p8" \
			--key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID required}" \
			--issuer "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID required}")
	elif [ -n "${NOTARY_PROFILE:-}" ]; then
		notary_args=(--keychain-profile "$NOTARY_PROFILE")
	else
		die "no notary credentials — set NOTARY_KEY_P8_BASE64 + NOTARY_KEY_ID + NOTARY_ISSUER_ID, or NOTARY_PROFILE (see this script's header)"
	fi
	notarize_zip() {
		local zip="$1"
		say "submitting $zip to the Apple notary service (this can take a few minutes)…"
		xcrun notarytool submit "$DIST/$zip" "${notary_args[@]}" --wait 2>&1 | tee "$TMP/notary.out" || true
		# notarytool can exit 0 even when the result is Invalid, so gate on the reported
		# status, not the exit code. (A zip of a folder can't be stapled; Gatekeeper does an
		# online check on first run instead — fine, the plugin is online anyway.)
		local nstatus nid
		nstatus="$( grep -E '^[[:space:]]*status:' "$TMP/notary.out" | tail -1 | awk '{print $NF}' )"
		if [ "$nstatus" != "Accepted" ]; then
			nid="$( grep -Eo 'id: [0-9a-fA-F-]{36}' "$TMP/notary.out" | head -1 | awk '{print $2}' )"
			[ -n "$nid" ] && { say "notarization $nstatus — Apple's issues:"; xcrun notarytool log "$nid" "${notary_args[@]}" 2>&1 | head -60; }
			die "notarization of $zip did not pass (status: ${nstatus:-unknown}); fix the issues above and re-run"
		fi
		say "notarization Accepted: $zip"
	}
	notarize_zip "$ZIP_MAC"
	notarize_zip "$ZIP_ALL"
fi

if [ "$DO_SIGN" = "1" ]; then
	say "done — signed + notarized: $DIST/$ZIP_MAC, $DIST/$ZIP_ALL (+ win zip; lens-helper.exe unsigned until Azure Trusted Signing lands)"
else
	say "done — UNSIGNED (packaging only, testing use): $DIST/SpeciesTagger-$VERSION-{mac,win,all}.zip"
	say "re-run with a Developer ID identity + notary credentials for a distributable build."
fi
