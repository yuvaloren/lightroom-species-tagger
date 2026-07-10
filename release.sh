#!/usr/bin/env bash
# release.sh — ONE command: from a clean checkout to a signed, notarized,
# PUBLISHED release (the three per-platform zips + checksums on a GitHub Release).
#
#   ./release.sh                   # sign + notarize + package + publish to GitHub
#   ./release.sh --no-publish      # everything except the GitHub Release (dry run)
#   ./release.sh --allow-unsigned  # before the Developer ID exists (universal Node
#                                  # only; implies no publish — never distributable)
#
# It bootstraps everything it needs and runs the whole pipeline in one process:
#   pinned Lua toolchain (.lua-env)  ->  Lens helper deps (npm ci)  ->  compose the
#   release bundle (darwin universal + win-x64)  ->  universal Node + Developer ID
#   sign + notarize  ->  package the three zips (scripts/package-zips.sh)  ->
#   gh release create with all assets.
#
# Signing runs ONLY here, on this Mac — never in CI. The signing identity and notary
# credentials stay in the login keychain + a gitignored scripts/signing.env that this
# script sources (decision 2026-07-09: no signing secrets on GitHub). CI validates;
# release.sh ships.
#
# Publishing requires the release tag to exist at HEAD (cut it first — see
# .claude/skills/cut-release). Genuine external prerequisites a script can't create:
# Node/npm, a C toolchain (for luarocks), `gh` logged in, and — for a signed build —
# a Developer ID identity + notary credentials (see docs/SIGNING.md).
set -euo pipefail
cd "$(dirname "$0")"
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mrelease:\033[0m %s\n' "$*" >&2; exit 1; }

NO_PUBLISH=0
ALLOW_UNSIGNED=0
SIGN_ARGS=()
for a in "$@"; do
	case "$a" in
		--no-publish) NO_PUBLISH=1 ;;
		--allow-unsigned) ALLOW_UNSIGNED=1; SIGN_ARGS+=( "$a" ) ;;
		*) SIGN_ARGS+=( "$a" ) ;;
	esac
done

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

# 2. Lens helper deps (puppeteer-core) — ALWAYS npm ci: it's cheap (pure JS) and
# guarantees the bundle ships exactly the lockfile, never a stale node_modules
# left over from before a dependency bump.
say "vendoring the Lens helper deps (cd scripts/lens && npm ci)"
( cd scripts/lens && npm ci )

# 3. Compose the release bundle: darwin arm64 (universal source) + win-x64.
say "composing the release bundle"
ST_NODE_PLATFORMS=darwin-arm64,win-x64 bash build.sh --no-zip

# 4. Universal Node + Developer ID sign + notarize + package the three zips.
say "signing + packaging"
bash scripts/sign-macos.sh ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}

# 5. Publish the GitHub Release (all three zips + checksums.txt).
if [ "$NO_PUBLISH" = "1" ]; then
	say "release built (NOT published — --no-publish) -> output/dist/"
	exit 0
fi
[ "$ALLOW_UNSIGNED" = "0" ] || die "refusing to publish an unsigned build (drop --allow-unsigned, or add --no-publish)"

VERSION="$(tr -d '[:space:]' < VERSION)"
case "$VERSION" in
	*-dev*|dev|'') die "VERSION is '$VERSION' — a dev label never ships; cut a release version first (see .claude/skills/cut-release)" ;;
esac
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null \
	|| die "tag v$VERSION does not exist — cut it first (see .claude/skills/cut-release)"
[ "$(git rev-parse "v$VERSION^{commit}")" = "$(git rev-parse HEAD)" ] \
	|| die "tag v$VERSION is not at HEAD — check out the tagged commit to release it"
command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required to publish — or re-run with --no-publish"

say "publishing GitHub Release v$VERSION"
git push origin "v$VERSION" 2>/dev/null || true # ensure the tag is on the remote
NOTES_FILE=""
if command -v git-cliff >/dev/null 2>&1; then
	NOTES_FILE="$(mktemp)"
	git-cliff --config cliff.toml --latest --strip all -o "$NOTES_FILE" 2>/dev/null || NOTES_FILE=""
fi
ASSETS=( "output/dist/SpeciesTagger-$VERSION-mac.zip"
         "output/dist/SpeciesTagger-$VERSION-win.zip"
         "output/dist/SpeciesTagger-$VERSION-all.zip"
         "output/dist/checksums.txt" )
for f in "${ASSETS[@]}"; do [ -f "$f" ] || die "missing release asset: $f"; done
if [ -n "$NOTES_FILE" ] && [ -s "$NOTES_FILE" ]; then
	gh release create "v$VERSION" "${ASSETS[@]}" --title "v$VERSION" --notes-file "$NOTES_FILE"
else
	gh release create "v$VERSION" "${ASSETS[@]}" --title "v$VERSION" --generate-notes
fi
say "published: $(gh release view "v$VERSION" --json url -q .url)"
