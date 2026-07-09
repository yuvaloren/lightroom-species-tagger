#!/usr/bin/env bash
# sign-macos.sh — turn a freshly composed SpeciesTagger.lrplugin into a signed,
# notarized, universal-Node release zip for macOS.
#
# The plugin bundles a per-OS Node runtime. On macOS that binary is the one thing
# that breaks a plain download: an unsigned binary that arrives quarantined (browser
# download + Finder unzip) is blocked by Gatekeeper on first run. This script fixes it
# at the source:
#   1. lipo the two official darwin Node builds (arm64 + x64) into ONE universal binary
#      so a single bundle runs natively on Apple Silicon AND Intel — no plugin change
#      (resolveNode still finds node/darwin-arm64/node, which is now universal).
#   2. codesign every Mach-O in the bundle (the Node binary + the Lens helper's native
#      addons, e.g. bare-* *.bare files) with a Developer ID identity + hardened runtime.
#   3. notarize the packaged zip with notarytool (Gatekeeper then clears it on first run;
#      a bare binary/folder can't be stapled, but the plugin is online anyway).
#   4. repackage output/dist/SpeciesTagger.lrplugin-<version>.zip + checksums.txt.
#
# Run it AFTER composing the bundle:
#   ST_NODE_PLATFORMS=darwin-arm64,win-x64 lua build/build.lua --no-zip
#   bash scripts/sign-macos.sh
#
# Signing/notarization need an Apple Developer ID (see docs/SIGNING.md). Until you have
# it, run with --allow-unsigned to do the universal-binary + repackage steps only (handy
# to validate the lipo path now; the resulting zip is NOT for distribution).
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
NODE_BIN="$BUNDLE/node/darwin-arm64/node"
[ -d "$BUNDLE" ] || die "no bundle at $BUNDLE — compose first: ST_NODE_PLATFORMS=darwin-arm64,win-x64 lua build/build.lua --no-zip"
[ -f "$NODE_BIN" ] || die "expected arm64 Node at $NODE_BIN — compose with ST_NODE_PLATFORMS including darwin-arm64"

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
ZIP="SpeciesTagger.lrplugin-$VERSION.zip"

# ---- pinned Node version (single source of truth = build/build.lua) ---------
NODE_VERSION="$(grep -oE "NODE_VERSION = 'v[0-9][0-9.]*'" build/build.lua | grep -oE 'v[0-9][0-9.]*' | head -1)"
[ -n "$NODE_VERSION" ] || die "could not read NODE_VERSION from build/build.lua"

# ---- will we sign this run? -------------------------------------------------
DO_SIGN=1
if [ "$ALLOW_UNSIGNED" = "1" ] && [ -z "${MACOS_SIGN_IDENTITY:-}" ]; then DO_SIGN=0; fi
if [ "$DO_SIGN" = "1" ] && [ -z "${MACOS_SIGN_IDENTITY:-}" ]; then
	die "MACOS_SIGN_IDENTITY is required to sign (or pass --allow-unsigned to build the universal binary only). See docs/SIGNING.md"
fi
say "Node $NODE_VERSION · plugin $VERSION · sign=$DO_SIGN"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- 1. universal Node via lipo ---------------------------------------------
# The bundle already carries the arm64 slice; fetch the x64 slice from nodejs.org and
# lipo them into one universal binary in place.
if lipo -info "$NODE_BIN" 2>/dev/null | grep -q 'x86_64'; then
	say "node is already universal — skipping lipo"
else
	X64_TGZ="node-$NODE_VERSION-darwin-x64.tar.gz"
	say "fetching darwin-x64 Node ($NODE_VERSION) for the universal binary…"
	curl -fsSL -o "$TMP/$X64_TGZ" "https://nodejs.org/dist/$NODE_VERSION/$X64_TGZ"
	tar -xzf "$TMP/$X64_TGZ" -C "$TMP"
	X64_BIN="$TMP/node-$NODE_VERSION-darwin-x64/bin/node"
	[ -f "$X64_BIN" ] || die "unexpected Node archive layout: missing $X64_BIN"
	say "lipo: arm64 (bundled) + x86_64 (fetched) -> universal"
	lipo -create "$NODE_BIN" "$X64_BIN" -output "$TMP/node.universal"
	chmod +x "$TMP/node.universal"
	mv "$TMP/node.universal" "$NODE_BIN"
fi
lipo -info "$NODE_BIN"

# ---- 1b. drop prebuilt native addons for platforms we never run -------------
# The Lens helper's node_modules ships bare-*/prebuilds/<platform>/*.bare native binaries
# for many platforms. This plugin only runs under Node on macOS or Windows, so the
# iOS-simulator / linux / android prebuilds are dead weight — and Apple's guidance is that
# code you never run needn't be signed or ticketed. Strip them (keeps darwin + win32).
for plat in ios android linux; do
	find "$BUNDLE" -type d -path "*/prebuilds/${plat}-*" -exec rm -rf {} + 2>/dev/null || true
done

# ---- 2. codesign every Mach-O (Developer ID + hardened runtime) --------------
# The bundled Node is NOT the only native code: darwin/win32 native addons (bare-* *.bare)
# are Mach-O too. Apple rejects the archive if ANY Mach-O is unsigned, so we sign every
# Mach-O we find. The Node binary ALSO needs JIT entitlements (below) or V8 is killed by
# the hardened runtime at runtime.
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
	# The Node binary runs V8, which JITs. Under the hardened runtime, JIT is killed unless
	# these entitlements are present — and `codesign --force` WITHOUT --entitlements strips
	# the ones the official Node ships with. Omit the debug `get-task-allow` (notarization
	# forbids it). Only the main Node executable needs these; the .bare addons don't JIT.
	ENTITLEMENTS="$TMP/node-entitlements.plist"
	cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
PLIST
	say "codesign every Mach-O in the bundle (Developer ID + hardened runtime + timestamp)"
	signed=0
	while IFS= read -r -d '' f; do
		if file "$f" 2>/dev/null | grep -q 'Mach-O'; then
			if [ "$f" = "$NODE_BIN" ]; then
				codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$MACOS_SIGN_IDENTITY" "$f"
			else
				codesign --force --options runtime --timestamp --sign "$MACOS_SIGN_IDENTITY" "$f"
			fi
			signed=$(( signed + 1 ))
		fi
	done < <( find "$BUNDLE" -type f -print0 )
	say "signed $signed Mach-O binaries"
	codesign --verify --strict --verbose=2 "$NODE_BIN"
	codesign -d --entitlements - "$NODE_BIN" 2>/dev/null | grep -q 'allow-jit' \
		|| die "Node lacks the allow-jit entitlement — it would crash under the hardened runtime"
fi

# ---- 3. package the distributable zip + checksums ---------------------------
say "packaging $DIST/$ZIP"
( cd "$DIST" && rm -f ./*.zip checksums.txt && zip -qr "$ZIP" "SpeciesTagger.lrplugin" )
( cd "$DIST" && shasum -a 256 "$ZIP" > checksums.txt )

# ---- 4. notarize the packaged zip -------------------------------------------
if [ "$DO_SIGN" = "1" ]; then
	say "submitting to the Apple notary service (this can take a few minutes)…"
	notary_args=()
	if [ -n "${NOTARY_KEY_P8_BASE64:-}" ]; then
		printf '%s' "$NOTARY_KEY_P8_BASE64" | base64 --decode > "$TMP/AuthKey.p8"
		notary_args=(--key "$TMP/AuthKey.p8" \
			--key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID required}" \
			--issuer "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID required}")
	elif [ -n "${NOTARY_PROFILE:-}" ]; then
		notary_args=(--keychain-profile "$NOTARY_PROFILE")
	else
		die "no notary credentials — set NOTARY_KEY_P8_BASE64 + NOTARY_KEY_ID + NOTARY_ISSUER_ID, or NOTARY_PROFILE (see docs/SIGNING.md)"
	fi
	xcrun notarytool submit "$DIST/$ZIP" "${notary_args[@]}" --wait 2>&1 | tee "$TMP/notary.out" || true
	# notarytool can exit 0 even when the result is Invalid, so gate on the reported
	# status, not the exit code. (A zip of a folder can't be stapled; Gatekeeper does an
	# online check on first run instead — fine, the plugin is online anyway.)
	nstatus="$( grep -E '^[[:space:]]*status:' "$TMP/notary.out" | tail -1 | awk '{print $NF}' )"
	if [ "$nstatus" != "Accepted" ]; then
		nid="$( grep -Eo 'id: [0-9a-fA-F-]{36}' "$TMP/notary.out" | head -1 | awk '{print $2}' )"
		[ -n "$nid" ] && { say "notarization $nstatus — Apple's issues:"; xcrun notarytool log "$nid" "${notary_args[@]}" 2>&1 | head -60; }
		die "notarization did not pass (status: ${nstatus:-unknown}); fix the issues above and re-run"
	fi
	say "notarization Accepted."
fi

if [ "$DO_SIGN" = "1" ]; then
	say "done — signed + notarized: $DIST/$ZIP"
else
	say "done — UNSIGNED (universal binary only, testing use): $DIST/$ZIP"
	say "re-run with a Developer ID identity + notary credentials for a distributable build."
fi
