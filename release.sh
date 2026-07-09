#!/usr/bin/env bash
# release.sh — ONE command: from a clean checkout to a signed, notarized,
# distributable SpeciesTagger.lrplugin zip in output/dist/.
#
#   ./release.sh                   # full signed + notarized release
#   ./release.sh --allow-unsigned  # before the Developer ID exists (universal Node only)
#
# It bootstraps everything it needs and runs the whole pipeline in one process:
#   pinned Lua toolchain (.lua-env)  ->  Lens helper deps (npm ci)  ->  compose the
#   release bundle (darwin universal + win-x64)  ->  universal Node + Developer ID
#   sign + notarize + package.
#
# Signing config is read from the environment or a gitignored scripts/signing.env that
# this script sources, so the whole release is literally one command with nothing on the
# command line. Genuine external prerequisites a script can't create: Node/npm, a C
# toolchain (for luarocks), and — for a signed build — a Developer ID identity + notary
# credentials (see docs/SIGNING.md).
set -euo pipefail
cd "$(dirname "$0")"
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# 0. Signing config (optional, gitignored) so `./release.sh` needs nothing inline.
if [ -f scripts/signing.env ]; then
	say "loading scripts/signing.env"
	set -a
	# shellcheck source=/dev/null
	. scripts/signing.env
	set +a
fi

# 1. Pinned Lua 5.1 toolchain (.lua-env) — bootstrap if absent.
if [ ! -x .lua-env/bin/lua ]; then
	say "bootstrapping the pinned Lua toolchain (./dev-setup.sh)"
	bash dev-setup.sh
fi

# 2. Lens helper deps (puppeteer-core) — vendor if absent.
if [ ! -d scripts/lens/node_modules ]; then
	say "vendoring the Lens helper deps (cd scripts/lens && npm ci)"
	( cd scripts/lens && npm ci )
fi

# 3. Compose the release bundle: darwin arm64 (universal source) + win-x64.
say "composing the release bundle"
ST_NODE_PLATFORMS=darwin-arm64,win-x64 bash build.sh --no-zip

# 4. Universal Node + Developer ID sign + notarize + package (forwards --allow-unsigned).
say "signing + packaging"
bash scripts/sign-macos.sh "$@"

say "release ready -> output/dist/ (SpeciesTagger.lrplugin-<version>.zip + checksums.txt)"
