# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/) and the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial release. A Lightroom Classic plugin that identifies the plants and animals
  in selected photos and tags them with both the **common** and the **Latin
  (scientific)** name.
- **Google Lens recognition — free, no API key.** Lens has no anonymous API and
  renders results with JavaScript, so a bundled Node helper (`scripts/lens`) uploads
  the image, transplants an anonymous session into the user's installed Google Chrome
  (a visible window — Google's real page is shown, not scraped invisibly), and
  harvests the AI-Overview answer plus visual-match titles. Best-effort: a photo goes
  to *needs review* on any failure; a Google "are you human" check can be solved in
  the window on a single-photo run.
- **Keyless taxonomy** via the **GBIF** backbone: accepted scientific name, preferred
  common name, and the full Kingdom→Species classification for optional hierarchy
  keywords. An image-surfaced common name is preferred over GBIF's arbitrary first
  vernacular.
- **Confidence-scored, auto-apply-if-confident** tagging; uncertain photos get a
  `species: needs review` keyword instead of a guess. Multi-subject frames tag every
  species over threshold.
- **Add context to the search:** an optional per-run **extra keywords** prompt and the
  photo's **location** (GPS or IPTC place) are folded into the Lens search as a
  multisearch text refinement, and location is also used as browser geolocation.
- **Re-parse to correct results:** with "Keep the browser open" on, each photo's tab
  is stamped with the photo it belongs to; refine the wrong ones, then run **Plug-in
  Extras ▸ Re-tag from open Lens tabs** once to sweep every open Lens tab (no
  new upload) and re-tag each tab's own photo in a single batch.
- **First-run welcome** listing every setting and where to find it.
- **Cross-platform:** macOS, Linux, and Windows (Chrome discovery, process handling,
  and command building are platform-aware).
- **Offline, deterministic accuracy + regression harness:** a labelled, impersonal
  fixture corpus spanning several phyla, `scripts/accuracy.lua` reporting
  recall / top-1 / genus / family / false+, and a **threshold calibration sweep**
  (`live-accuracy --sweep`) that reports precision/recall at every auto-apply
  threshold so the operating point can be grounded in real data. See
  [docs/SCORING.md](docs/SCORING.md).
- **Self-contained releases:** CI bundles the Lens helper's dependencies into the
  `.lrplugin`, so end users unzip and run with no `npm install`. A separate CI job
  drives the real Lens helper against a local fake Google.
