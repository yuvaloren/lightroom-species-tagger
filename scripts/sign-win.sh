#!/usr/bin/env bash
# sign-win.sh — Authenticode-sign the Windows installer via Azure Trusted
# Signing. PLUGGABLE STUB until the Azure account's one-time setup (billing +
# identity validation — needs Yuval personally) is complete.
#
#   bash scripts/sign-win.sh output/dist/SpeciesTagger-win-setup.exe
#
# Contract: WIN_SIGN_CMD (scripts/signing.env) is a command that takes ONE
# argument — the exe to sign in place — and exits non-zero on failure. When
# Azure Trusted Signing is wired up, point WIN_SIGN_CMD at the signing wrapper
# (candidates, in preference order: the cross-platform `azuresigntool`-style
# CLI if it supports Trusted Signing by then, or an SSH invocation of signtool
# + the Trusted-Signing dlib on the Windows VM). Decision + status:
# docs/INSTALLERS-PLAN.md.
#
# Unsigned consequence: a one-time SmartScreen "More info > Run anyway" on
# first run — documented on the wiki's Installing page.
set -euo pipefail
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31msign-win:\033[0m %s\n' "$*" >&2; exit 1; }

EXE="${1:?usage: sign-win.sh <setup.exe>}"
[ -f "$EXE" ] || die "no such file: $EXE"

if [ -n "${WIN_SIGN_CMD:-}" ]; then
	say "signing $(basename "$EXE") via WIN_SIGN_CMD"
	$WIN_SIGN_CMD "$EXE"
	say "signed $(basename "$EXE")"
else
	say "WARNING: $(basename "$EXE") is NOT signed — Azure Trusted Signing pending"
	say "         (set WIN_SIGN_CMD in scripts/signing.env once the Azure account is validated)"
fi
