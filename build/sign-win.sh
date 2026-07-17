#!/usr/bin/env bash
# sign-win.sh — Authenticode-sign the Windows installer via Azure Trusted
# Signing, from macOS, as part of the one-command local release build.
#
#   bash build/sign-win.sh output/dist/SpeciesTagger-win-setup.exe
#
# How it signs (no secrets stored — consistent with "no signing secrets on
# GitHub, ever"): a short-lived Azure access token from `az account
# get-access-token` feeds jsign (cross-platform Authenticode signer with
# native Trusted Signing support), which asks the Trusted Signing service to
# sign the exe with the certificate profile and timestamps it (RFC 3161).
#
# Configuration (build/signing.env, gitignored — names, not secrets):
#   ATS_ENDPOINT   Trusted Signing regional endpoint, e.g. eus.codesigning.azure.net
#   ATS_ACCOUNT    Trusted Signing account name
#   ATS_PROFILE    certificate profile name
#   WIN_SIGN_CMD   (optional escape hatch) custom command taking the exe path;
#                  overrides the jsign path entirely.
#
# One-time prerequisites: `brew install azure-cli jsign`; `az login` with an
# identity holding the "Trusted Signing Certificate Profile Signer" role.
# If nothing is configured, the exe ships UNSIGNED (one-time SmartScreen
# "More info > Run anyway" — noted in README/wiki).
set -euo pipefail
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31msign-win:\033[0m %s\n' "$*" >&2; exit 1; }

EXE="${1:?usage: sign-win.sh <setup.exe>}"
[ -f "$EXE" ] || die "no such file: $EXE"

# Escape hatch first.
if [ -n "${WIN_SIGN_CMD:-}" ]; then
	say "signing $(basename "$EXE") via WIN_SIGN_CMD"
	$WIN_SIGN_CMD "$EXE"
	say "signed $(basename "$EXE")"
	exit 0
fi

if [ -z "${ATS_ENDPOINT:-}" ] || [ -z "${ATS_ACCOUNT:-}" ] || [ -z "${ATS_PROFILE:-}" ]; then
	say "WARNING: $(basename "$EXE") is NOT signed — Azure Trusted Signing not configured"
	say "         (set ATS_ENDPOINT/ATS_ACCOUNT/ATS_PROFILE in build/signing.env; see header)"
	exit 0
fi

command -v az >/dev/null 2>&1 || die "azure-cli not found — brew install azure-cli && az login"
command -v jsign >/dev/null 2>&1 || die "jsign not found — brew install jsign"

say "fetching a short-lived Trusted Signing token (az)"
TOKEN="$(az account get-access-token --resource https://codesigning.azure.net --query accessToken -o tsv)" \
	|| die "az account get-access-token failed — run 'az login' first"
[ -n "$TOKEN" ] || die "empty access token from az"

say "signing $(basename "$EXE") via Azure Trusted Signing ($ATS_ACCOUNT/$ATS_PROFILE @ $ATS_ENDPOINT)"
jsign --storetype TRUSTEDSIGNING \
	--keystore "$ATS_ENDPOINT" \
	--storepass "$TOKEN" \
	--alias "$ATS_ACCOUNT/$ATS_PROFILE" \
	--tsaurl http://timestamp.acs.microsoft.com \
	--tsmode RFC3161 \
	"$EXE"

# Local structural check (the authoritative check is Get-AuthenticodeSignature
# on a real Windows box — done in the release testing pass).
if command -v osslsigncode >/dev/null 2>&1; then
	osslsigncode verify -in "$EXE" >/dev/null 2>&1 \
		&& say "signature verified (osslsigncode)" \
		|| say "NOTE: osslsigncode could not fully verify (missing MS root store locally is common) — verify on Windows"
fi
say "signed $(basename "$EXE")"
