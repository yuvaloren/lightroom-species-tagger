#!/usr/bin/env bash
# check-node-eol.sh — fail when the BUNDLED Node runtime (NODE_VERSION in
# build/build.lua, the binary every end user runs) is end-of-life, within 60 days
# of it, or out of sync with scripts/lens/.nvmrc.
#
# Why this exists: Dependabot watches package.json and GitHub Actions, but a custom
# pin like NODE_VERSION is invisible to it — v0.1.0 shipped Node 20 two months
# after its 2026-04-30 EOL and nothing fired. This guard runs weekly in CI
# (.github/workflows/node-eol.yml) so the alarm sounds even when nobody touches
# the repo. Data source: the endoflife.date API.
set -euo pipefail
cd "$(dirname "$0")/.."

NODE_VERSION="$(grep -oE "NODE_VERSION = 'v[0-9][0-9.]*'" build/build.lua | grep -oE 'v[0-9][0-9.]*' | head -1)"
[ -n "$NODE_VERSION" ] || { echo "::error::could not read NODE_VERSION from build/build.lua"; exit 1; }
MAJOR="${NODE_VERSION#v}"; MAJOR="${MAJOR%%.*}"

NVMRC="$(tr -d '[:space:]' < scripts/lens/.nvmrc)"
if [ "${NVMRC%%.*}" != "$MAJOR" ]; then
	echo "::error::scripts/lens/.nvmrc ($NVMRC) disagrees with build.lua NODE_VERSION ($NODE_VERSION) — keep the majors in lock-step"
	exit 1
fi

curl -fsSL --retry 3 https://endoflife.date/api/nodejs.json -o /tmp/nodejs-eol.json

python3 - "$MAJOR" "$NODE_VERSION" <<'PY'
import datetime, json, sys

major, pinned = sys.argv[1], sys.argv[2]
cycles = json.load(open('/tmp/nodejs-eol.json'))
cycle = next((c for c in cycles if str(c.get('cycle')) == major), None)
if cycle is None:
    print(f"::error::Node {major} not found in endoflife.date data")
    sys.exit(1)

eol = cycle.get('eol')
today = datetime.date.today()
if eol is True:
    print(f"::error::bundled Node {pinned} is END-OF-LIFE — bump NODE_VERSION in build/build.lua (and scripts/lens/.nvmrc) to the newest Active LTS")
    sys.exit(1)
if isinstance(eol, str):
    eol_date = datetime.date.fromisoformat(eol)
    days = (eol_date - today).days
    if days <= 0:
        print(f"::error::bundled Node {pinned} is END-OF-LIFE (since {eol}) — bump NODE_VERSION in build/build.lua (and scripts/lens/.nvmrc) to the newest Active LTS")
        sys.exit(1)
    if days <= 60:
        print(f"::error::bundled Node {pinned} reaches EOL on {eol} ({days} days) — bump NODE_VERSION now, before it ships EOL")
        sys.exit(1)

latest = cycle.get('latest')
if latest and latest != pinned.lstrip('v'):
    print(f"::notice::a newer Node {major} patch exists: v{latest} (pinned: {pinned}) — consider bumping")
print(f"ok: Node {pinned} is supported (eol: {eol})")
PY
