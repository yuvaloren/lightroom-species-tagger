#!/usr/bin/env bash
# release.sh — THE release: one command, no AI in the loop, from a -dev tree to
# a published GitHub Release + synced wiki, with development reopened after.
#
#   ./release.sh                    # full release (stages below)
#   ./release.sh --version 0.4.0    # override the target (minor/major jumps)
#   ./release.sh --yes              # skip the single confirmation prompt
#   ./release.sh --no-publish       # build-only dry run of the CURRENT tree:
#                                   # no bump, no tag, no publish, no wiki
#   ./release.sh --allow-unsigned   # (dry runs only) build before signing exists
#
# Full-release stages — everything IRREVERSIBLE happens only after the whole
# build has succeeded and you've confirmed:
#   1. pre-flight: clean tree, on main, synced with origin, gh authed
#   2. target version = VERSION minus "-dev" (or --version); tag must be new
#   3. VERSION written (uncommitted yet); CHANGELOG "## [X.Y.Z]" reused if you
#      wrote it during development, else generated from conventional commits
#      (git-cliff --prepend)
#   4. lint + tests (pinned .lua-env toolchain — same gate as CI)
#   5. the full artifact pipeline: compose (darwin universal + win-x64),
#      Developer ID sign + notarize, three zips, stapled pkg, Windows
#      installer (Azure Trusted Signing once configured), checksums
#   6. >>> the ONE y/N confirmation (version + changelog + assets) <<<
#   7. commit VERSION+CHANGELOG, tag vX.Y.Z, push commit + tag
#   8. CI gate: wait for green checks on the tagged commit. CI validates and
#      never signs or publishes — no signing secrets on GitHub, ever; the
#      signing identity + notary credentials stay in the login keychain and
#      the gitignored scripts/signing.env this script sources.
#   9. gh release create with the six assets, then wiki sync (public LAST,
#      so the wiki's evergreen download links never precede the assets)
#  10. verify: six assets on the Release; latest/download URLs resolve
#  11. reopen development at X.Y.(Z+1)-dev, commit, push
#
# Genuine external prerequisites a script can't create: Node/npm, a C
# toolchain (luarocks), `gh` logged in, the signing/notary setup
# (docs/SIGNING.md), and dev rocks in .lua-env (bootstrapped on first run).
set -euo pipefail
cd "$(dirname "$0")"
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mrelease:\033[0m %s\n' "$*" >&2; exit 1; }

REPO_SLUG="yuvaloren/lightroom-species-tagger"

NO_PUBLISH=0
ALLOW_UNSIGNED=0
ASSUME_YES=0
TARGET=""
SIGN_ARGS=()
for a in "$@"; do
	case "$a" in
		--no-publish) NO_PUBLISH=1 ;;
		--yes) ASSUME_YES=1 ;;
		--version=*) TARGET="${a#--version=}" ;;
		--allow-unsigned) ALLOW_UNSIGNED=1; SIGN_ARGS+=( "$a" ) ;;
		*) SIGN_ARGS+=( "$a" ) ;;
	esac
done
[ "$ALLOW_UNSIGNED" = "0" ] || [ "$NO_PUBLISH" = "1" ] \
	|| die "--allow-unsigned is for dry runs — add --no-publish (an unsigned build never ships)"

# 0. Signing config (optional, gitignored) so `./release.sh` needs nothing inline.
if [ -f scripts/signing.env ]; then
	say "loading scripts/signing.env"
	set -a
	# shellcheck source=/dev/null
	. scripts/signing.env
	set +a
fi

# ---- release-mode gates BEFORE any expensive work ----------------------------
if [ "$NO_PUBLISH" = "0" ]; then
	command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required to publish"
	gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"

	# 1. pre-flight: clean tree, on main, synced with origin
	[ -z "$(git status --porcelain)" ] || die "working tree is not clean — commit or stash first"
	BRANCH="$(git rev-parse --abbrev-ref HEAD)"
	[ "$BRANCH" = "main" ] || die "releases are cut from main (you are on $BRANCH)"
	say "pre-flight: fetching origin"
	git fetch -q origin main
	[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
		|| die "main is not in sync with origin/main — push or pull first"

	# 2. resolve the target version
	RAW="$(tr -d '[:space:]' < VERSION)"
	if [ -z "$TARGET" ]; then
		case "$RAW" in
			*-dev) TARGET="${RAW%-dev}" ;;
			*) die "VERSION is '$RAW' (not '-dev') — development wasn't reopened after the last release; fix VERSION or pass --version=X.Y.Z" ;;
		esac
	fi
	printf '%s' "$TARGET" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
		|| die "target version '$TARGET' is not plain X.Y.Z"
	! git rev-parse -q --verify "refs/tags/v$TARGET" >/dev/null \
		|| die "tag v$TARGET already exists locally"
	[ -z "$(git ls-remote --tags origin "refs/tags/v$TARGET")" ] \
		|| die "tag v$TARGET already exists on origin"
	say "releasing v$TARGET (from VERSION=$RAW)"

	# 3. VERSION + CHANGELOG (working tree only — committed at stage 7)
	printf '%s\n' "$TARGET" > VERSION
	if grep -q "## \[$TARGET\]" CHANGELOG.md; then
		say "CHANGELOG already has the [$TARGET] section (hand-written) — using it"
	else
		command -v git-cliff >/dev/null 2>&1 \
			|| die "CHANGELOG has no [$TARGET] section and git-cliff is not installed (brew install git-cliff, or write the section by hand)"
		say "generating the CHANGELOG [$TARGET] section from conventional commits"
		git-cliff --config cliff.toml --unreleased --tag "v$TARGET" --prepend CHANGELOG.md
		grep -q "## \[$TARGET\]" CHANGELOG.md \
			|| die "git-cliff did not produce a [$TARGET] heading — write it by hand and re-run"
	fi

	# 4. lint + tests (the same gate CI runs; the build itself is stage 5)
	[ -x .lua-env/bin/lua ] || { say "bootstrapping the pinned Lua toolchain (./dev-setup.sh)"; bash dev-setup.sh; }
	export PATH="$PWD/.lua-env/bin:$PATH"
	command -v luacheck >/dev/null 2>&1 || die "luacheck not in .lua-env — run: just deps"
	command -v busted >/dev/null 2>&1 || die "busted not in .lua-env — run: just deps"
	say "lint"
	luacheck -q src spec scripts
	say "tests"
	busted
fi

# ---- the artifact pipeline (shared by dry runs and real releases) ------------
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

# 4b. One-click installers (payloads come FROM the zips — single packaging truth).
# Unversioned asset names so the wiki's /releases/latest/download/ links are evergreen.
say "building the macOS pkg installer"
ALLOW_UNSIGNED="$ALLOW_UNSIGNED" bash scripts/build-pkg.sh
say "building the Windows installer"
bash scripts/build-win-installer.sh
say "appending installer checksums"
( cd output/dist && shasum -a 256 SpeciesTagger-mac.pkg SpeciesTagger-win-setup.exe >> checksums.txt )

if [ "$NO_PUBLISH" = "1" ]; then
	say "release built (NOT published — --no-publish) -> output/dist/"
	exit 0
fi

VERSION="$TARGET"
ASSETS=( "output/dist/SpeciesTagger-mac.pkg"
         "output/dist/SpeciesTagger-win-setup.exe"
         "output/dist/SpeciesTagger-$VERSION-mac.zip"
         "output/dist/SpeciesTagger-$VERSION-win.zip"
         "output/dist/SpeciesTagger-$VERSION-all.zip"
         "output/dist/checksums.txt" )
for f in "${ASSETS[@]}"; do [ -f "$f" ] || die "missing release asset: $f"; done

# ---- 6. the ONE confirmation --------------------------------------------------
say "about to release v$VERSION with these assets:"
for f in "${ASSETS[@]}"; do printf '      %s\n' "$(basename "$f")"; done
say "CHANGELOG section:"
awk -v h="## [$VERSION]" 'index($0,h)==1{on=1} on && index($0,h)!=1 && /^## /{exit} on{print "      " $0}' CHANGELOG.md
if [ "$ASSUME_YES" = "0" ]; then
	[ -t 0 ] || die "stdin is not a terminal — pass --yes to release unattended"
	printf '\033[1mTag v%s, push, and publish? Everything after this is irreversible. [y/N] \033[0m' "$VERSION"
	read -r REPLY
	[ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ] || die "aborted (nothing committed, tagged, or pushed — VERSION/CHANGELOG edits remain in the working tree)"
fi

# ---- 7. commit, tag, push ------------------------------------------------------
say "committing VERSION + CHANGELOG and tagging v$VERSION"
git add VERSION CHANGELOG.md
git commit -q -m "chore(release): v$VERSION"
git tag "v$VERSION"
git push -q origin main
git push -q origin "v$VERSION"
SHA="$(git rev-parse HEAD)"

# ---- 8. CI gate (validation only — the drift guard, build, lens-helper) --------
say "waiting for CI on $SHA (this is CI validating, never publishing)"
CI_OK=0
for _ in $(seq 1 120); do # up to ~20 minutes
	COUNTS="$(gh run list --commit "$SHA" --json status,conclusion \
		--jq '[length, ([.[] | select(.status=="completed")] | length), ([.[] | select(.conclusion=="success")] | length)] | @tsv' 2>/dev/null || echo '')"
	if [ -n "$COUNTS" ]; then
		TOTAL="$(cut -f1 <<< "$COUNTS")"; DONE="$(cut -f2 <<< "$COUNTS")"; GOOD="$(cut -f3 <<< "$COUNTS")"
		if [ "$TOTAL" -gt 0 ] && [ "$DONE" = "$TOTAL" ]; then
			if [ "$GOOD" = "$TOTAL" ]; then CI_OK=1; break; fi
			gh run list --commit "$SHA"
			die "CI failed on v$VERSION. Recover: fix the problem, then
        git tag -d v$VERSION && git push --delete origin v$VERSION
        git revert or amend as needed, and re-run ./release.sh"
		fi
	fi
	sleep 10
done
[ "$CI_OK" = "1" ] || die "timed out waiting for CI on $SHA — check 'gh run list', then re-run ./release.sh --version=$VERSION after deleting the tag if needed"
say "CI green"

# ---- 9. publish the GitHub Release + sync the wiki ------------------------------
say "publishing GitHub Release v$VERSION"
NOTES_FILE=""
if command -v git-cliff >/dev/null 2>&1; then
	NOTES_FILE="$(mktemp)"
	git-cliff --config cliff.toml --latest --strip all -o "$NOTES_FILE" 2>/dev/null || NOTES_FILE=""
fi
if [ -n "$NOTES_FILE" ] && [ -s "$NOTES_FILE" ]; then
	gh release create "v$VERSION" "${ASSETS[@]}" --title "v$VERSION" --notes-file "$NOTES_FILE"
else
	gh release create "v$VERSION" "${ASSETS[@]}" --title "v$VERSION" --generate-notes
fi

# The wiki is public the moment it's pushed — deliberately the LAST publish step,
# after the release is live, so wiki download links never point at missing assets.
say "syncing the GitHub wiki"
bash scripts/sync-wiki.sh

# ---- 10. verify ------------------------------------------------------------------
say "verifying the release"
N_ASSETS="$(gh release view "v$VERSION" --json assets --jq '.assets | length')"
[ "$N_ASSETS" = "6" ] || die "expected 6 assets on v$VERSION, found $N_ASSETS"
for a in SpeciesTagger-mac.pkg SpeciesTagger-win-setup.exe; do
	URL="https://github.com/$REPO_SLUG/releases/latest/download/$a"
	OK=0
	for _ in $(seq 1 30); do # 'latest' can lag the release by a few seconds
		if curl -fsIL -o /dev/null "$URL"; then OK=1; break; fi
		sleep 5
	done
	[ "$OK" = "1" ] || die "evergreen link does not resolve: $URL"
	say "resolves: $URL"
done
say "published: $(gh release view "v$VERSION" --json url -q .url)"

# ---- 11. reopen development --------------------------------------------------------
IFS=. read -r MA MI PA <<< "$VERSION"
NEXT="$MA.$MI.$(( PA + 1 ))-dev"
say "reopening development at $NEXT"
printf '%s\n' "$NEXT" > VERSION
git add VERSION
git commit -q -m "chore: reopen development at $NEXT"
git push -q origin main
say "done — v$VERSION is live, main is at $NEXT"
