#!/usr/bin/env bash
# debug-lens.sh — run the Google Lens helper in a VISIBLE Chrome window with full
# debug artifacts, so you can watch the upload and see exactly what Google returned
# and what we scraped. Use this to troubleshoot a wrong identification.
#
#   ./debug-lens.sh <image.jpg>                         # no location
#   ./debug-lens.sh <image.jpg> 36.62 -121.90           # GPS lat lng
#   ./debug-lens.sh <image.jpg> "Monterey, California"   # place name (geocoded)
#
# Export the SAME photo Lightroom would send (a ~1024px-long-edge JPEG) and pass it
# here. Artifacts land in LENS_DEBUG_DIR (default /tmp/lens-debug); the window stays
# open until you press Ctrl-C.
set -euo pipefail

cd "$(dirname "$0")"
img="${1:?usage: ./debug-lens.sh <image.jpg> [lat lng | \"City, State, Country\"]}"
shift
dir="${LENS_DEBUG_DIR:-/tmp/lens-debug}"
rm -rf "$dir"; mkdir -p "$dir"

echo "==> headed Lens debug run"
echo "    image:     $img"
echo "    artifacts: $dir/{results-url.txt,uploaded.jpg,page.png,page.html,strings-sources.json,result.json}"
echo "    Watch the window: is the UPLOADED image your photo, and do the matches look right?"
echo "    Then open results-url.txt in your own logged-in Chrome to compare. Ctrl-C to close."
echo

LENS_HEADED=1 LENS_DEBUG=1 LENS_SLOWMO=250 LENS_KEEP_OPEN=1 LENS_DEBUG_DIR="$dir" \
	node scripts/lens/lens-search.js "$img" "$@"
