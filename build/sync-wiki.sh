#!/usr/bin/env bash
# sync-wiki.sh — regenerate the GitHub wiki from the repo and push it.
#
# The wiki is PUBLIC the moment it's pushed, so this script runs in exactly one
# place: the end of release.sh, AFTER the GitHub Release is live — never from
# CI, never mid-development. (Run it by hand only for a deliberate wiki fix.)
#
# No-drift design (same principle as package-zips.sh): wiki pages are never
# hand-edited on github.com. They are generated here from single sources:
#
#   Home, _Sidebar        wiki/Home.md, wiki/_Sidebar.md   (authored, wiki-only)
#   Installing            README "## Install" section
#   Using-it, Settings    README "## Using it" / "## Settings" sections
#   FAQ                   wiki/FAQ.md  (user-facing source)
#   Privacy               wiki/Privacy.md
#   images/               wiki/images/
#
# One-time bootstrap: GitHub only creates the .wiki.git repo when the wiki's
# first page is saved in the web UI. Until then, cloning fails and this script
# dies with instructions.
set -euo pipefail
cd "$(dirname "$0")/.." # repo root
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31msync-wiki:\033[0m %s\n' "$*" >&2; exit 1; }

WIKI_REMOTE="git@github.com:yuvaloren/lightroom-species-tagger.wiki.git"

# Extract one "## Heading" section (heading line included) from a markdown file.
section() { # $1 = file, $2 = exact heading text (without ##)
	awk -v h="## $2" '
		$0 == h { on=1 }
		on && $0 != h && /^## / { exit }
		on { print }
	' "$1"
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say "cloning the wiki repo"
git clone --quiet --depth 1 "$WIKI_REMOTE" "$TMP/wiki" 2>/dev/null \
	|| die "cannot clone $WIKI_REMOTE — if the wiki was never initialized, create its first page once in the web UI (any content), then re-run"

W="$TMP/wiki"

# ---- authored wiki pages (the user-facing docs live here now) -------------------
# Home carries a "latest version" line. The newest v* tag is the source of truth
# for what is released — the VERSION file can't be: it is already X.Y.(Z+1)-dev
# whenever this script is run by hand for a wiki fix.
LATEST_TAG="$(git tag --list 'v*' --sort=-v:refname | head -n 1)"
[ -n "$LATEST_TAG" ] || die "no v* release tag found — cannot stamp Home's version line"
REL_DATE="$(git log -1 --format=%cs "$LATEST_TAG")"
grep -q '{{VERSION}}' wiki/Home.md \
	|| die "wiki/Home.md has no {{VERSION}} placeholder — restore the version line or update build/sync-wiki.sh"
sed -e "s/{{VERSION}}/${LATEST_TAG#v}/g" -e "s/{{RELEASE_DATE}}/$REL_DATE/g" \
	wiki/Home.md > "$W/Home.md"
! grep -q '{{' "$W/Home.md" || die "unsubstituted {{...}} placeholder left in Home.md"
cp wiki/_Sidebar.md "$W/_Sidebar.md"
cp wiki/FAQ.md "$W/FAQ.md"
cp wiki/Privacy.md "$W/Privacy.md"
rm -f "$W/Troubleshooting.md" # page retired (folded into the FAQ) — must also be removed from the wiki clone, or the stale page lives on forever
if [ -d wiki/images ]; then
	mkdir -p "$W/images"
	cp wiki/images/* "$W/images/" 2>/dev/null || true
fi

# ---- pages generated from the README --------------------------------------------
{
	section README.md "Install (from a release)"
	printf '\n---\n*This page is generated from the repo README — edit there, not here.*\n'
} > "$W/Installing.md"
{
	section README.md "Using it"
	printf '\n---\n*This page is generated from the repo README — edit there, not here.*\n'
} > "$W/Using-it.md"
{
	section README.md "Settings"
	printf '\n---\n*This page is generated from the repo README — edit there, not here.*\n'
} > "$W/Settings.md"
for f in Installing Using-it Settings; do
	[ -s "$W/$f.md" ] || die "extracted nothing for $f — did a README heading change? update build/sync-wiki.sh"
done

# ---- commit + push if anything changed --------------------------------------------
cd "$W"
git add -A
if git diff --cached --quiet; then
	say "wiki already up to date"
	exit 0
fi
git -c user.name="release.sh" -c user.email="yuval@bluecast.com" \
	commit --quiet -m "Sync wiki from repo ($(git -C "$OLDPWD" rev-parse --short HEAD 2>/dev/null || echo release))"
git push --quiet
say "wiki pushed"
