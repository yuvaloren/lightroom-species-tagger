#!/usr/bin/env bash
# capture.sh — capture REAL Google Lens output for a ground-truth corpus and save
# it for offline replay/tuning, so accuracy runs never have to re-hit Google.
# Needs Node.js + Google Chrome + a residential network (datacenter IPs are
# blocked). Re-runnable; captures overwrite the per-image cache.
#
#   ./capture.sh                              # capture the default iNaturalist corpus
#   ./capture.sh fixtures.groundtruth.monterey [--limit N] [--throttle S]
#
# The default corpus (spec/fixtures/groundtruth/monterey.lua) is built from open
# iNaturalist research-grade observations — build it first (with its open-licensed
# images) via:  lua scripts/build-inat-corpus.lua
#
# Captures land in spec/fixtures/live/<corpus>/ (gitignored). Replay/score them
# offline with: lua scripts/live-accuracy.lua --groundtruth <module>
set -euo pipefail

cd "$(dirname "$0")"
[[ -x .lua-env/bin/lua ]] && export PATH="$PWD/.lua-env/bin:$PATH"
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# An explicit ground-truth module (+ any extra flags) -> just that one.
if [[ "${1:-}" == fixtures.* ]]; then
	gt="$1"; shift
	say "capturing Google Lens output for $gt"
	exec lua scripts/live-accuracy.lua --groundtruth "$gt" --capture "$@"
fi

# Otherwise capture the default open iNaturalist corpus.
gt=fixtures.groundtruth.monterey
say "capturing Google Lens output for $gt"
exec lua scripts/live-accuracy.lua --groundtruth "$gt" --capture "$@"
