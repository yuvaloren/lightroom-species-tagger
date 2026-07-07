# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/) and the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial release. A Lightroom Classic plugin that tags the plants and animals in your
  photos with both the **common** and the **Latin (scientific)** name — assisted by
  Google Lens, decided by you.
- **Assistive Google Lens — free, no API key, no scraping.** A bundled Node helper
  (`scripts/lens`) uploads the image the way the Lens website does and opens the results
  in your installed Google Chrome (a **visible** window). You read Google's real page,
  **highlight** the species name, and press **Tag** in a bottom bar; the plugin uses only
  that selection (`window.getSelection()`) and never reads the page. This keeps it within
  Google's terms — no automated access to, or extraction of, Google's results.
- **Keyless taxonomy** via the **GBIF** backbone: whatever you highlight (a common name or
  a binomial) is resolved to the accepted scientific name, a preferred common name, and
  the full Kingdom→Species classification for optional hierarchy keywords.
- **Multi-photo flow:** one Chrome window is reused across photos (a fresh tab each) with a
  "Photo m of n" counter and a **Skip** button; the window is closed cleanly at the end.
- **First-run welcome** explaining the flow.
- **Cross-platform:** macOS, Linux, and Windows (Chrome/Node discovery and process
  handling are platform-aware).
- **Self-contained releases:** CI bundles the Lens helper's dependencies into the
  `.lrplugin`, so end users unzip and run with no `npm install`. A separate CI job drives
  the real Lens helper against a local fake Google.
