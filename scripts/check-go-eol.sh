#!/usr/bin/env bash
# check-go-eol.sh — fail when the Go toolchain pinned in helper/go.mod (the
# compiler every shipped helper binary is built with) is end-of-life.
#
# Why this exists: Dependabot watches go.mod DEPENDENCIES but not the go /
# toolchain directives — the same blind spot that once let this repo ship an
# EOL Node runtime for two months with no alarm. Go keeps exactly the two
# newest majors supported (no long-notice EOL dates), so: pinned cycle EOL →
# hard fail; pinned cycle supported but no longer the newest → loud warning
# (one more Go release makes it EOL — bump before that). Data source: the
# endoflife.date API. Runs weekly via .github/workflows/go-eol.yml.
set -euo pipefail
cd "$(dirname "$0")/.."

PIN="$(grep -E '^(toolchain go|go )' helper/go.mod | tail -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')"
[ -n "$PIN" ] || { echo "::error::could not read the Go pin from helper/go.mod"; exit 1; }
CYCLE="$(echo "$PIN" | cut -d. -f1-2)"

curl -fsSL --retry 3 https://endoflife.date/api/go.json -o /tmp/go-eol.json

python3 - "$CYCLE" "$PIN" <<'PY'
import json, sys

cycle_wanted, pinned = sys.argv[1], sys.argv[2]
cycles = json.load(open('/tmp/go-eol.json'))
cycle = next((c for c in cycles if str(c.get('cycle')) == cycle_wanted), None)
if cycle is None:
    print(f"::error::Go {cycle_wanted} not found in endoflife.date data")
    sys.exit(1)

# Go's eol field is a boolean today; treat a date string as EOL-announced and
# fail early rather than parse-and-wait — a Go bump is cheap.
if cycle.get('eol') is not False:
    print(f"::error::pinned Go {pinned} is END-OF-LIFE — bump helper/go.mod (go + toolchain) to the newest stable Go")
    sys.exit(1)

newest = str(cycles[0].get('cycle'))
if newest != cycle_wanted:
    print(f"::warning::Go {cycle_wanted} is no longer the newest cycle ({newest} is out) — one more Go release makes it EOL; bump helper/go.mod soon")

latest = cycle.get('latest')
if latest and latest != pinned:
    print(f"::notice::a newer Go {cycle_wanted} patch exists: {latest} (pinned: {pinned}) — consider bumping")
print(f"ok: Go {pinned} is supported (eol: {cycle.get('eol')})")
PY
