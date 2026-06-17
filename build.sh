#!/usr/bin/env bash
# build.sh — build the SpeciesTagger.lrplugin bundle into dist/.
#
# On the very FIRST build (when no Google Lens results have been captured yet) it
# also captures real Lens output for the ground-truth corpus, so accuracy/tuning
# work has real data to replay offline. That capture is best-effort and needs
# Chrome + a residential network — skip it with SKIP_CAPTURE=1, or run it yourself
# any time with ./capture.sh. (`just build` is the plain, no-capture variant.)
set -euo pipefail

cd "$(dirname "$0")"
[[ -x .lua-env/bin/lua ]] && export PATH="$PWD/.lua-env/bin:$PATH"
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# First-run Lens capture: only if we've never captured, the corpus images are
# present, and the caller hasn't opted out. Never fatal — building comes first.
captured="$(find spec/fixtures/live -maxdepth 2 -name '*.json' -not -path '*/gbif/*' 2>/dev/null | head -1)"
have_images="$(ls spec/fixtures/images/*.jpg 2>/dev/null | head -1)"
if [[ -z "${SKIP_CAPTURE:-}" && -z "$captured" && -n "$have_images" ]]; then
	say "no captured Lens results yet — capturing once (needs Chrome + residential network)."
	say "skip with SKIP_CAPTURE=1; (re)capture any time with ./capture.sh."
	bash "$(dirname "$0")/capture.sh" || say "WARNING: capture failed — building anyway; run ./capture.sh later."
fi

say "building the plugin bundle into dist/"
exec lua build/build.lua "$@"
