# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/) and the project follows
[Semantic Versioning](https://semver.org/).

## [0.4.0]

### Added

- Automatic burst detection: near-identical frames shot within a configurable gap
  (default 1 s) are grouped, and one Google Lens identification tags the whole
  burst — Tag, Skip, and Undo act on the group.
- Highlight snapping: your selection cleans itself the moment you release the
  mouse, before you press Tag, so you see the corrected highlight. Parentheses,
  quotes, commas and stray spaces fall off the edges, and a half-selected word
  completes to its boundaries — so catching a "(" or missing the first letter no
  longer sends the wrong text to be identified.

### Changed

- Reduced the plugin size substantially.

## [0.3.0] - 2026-07-10

### Added

- One-click installers, wiki pipeline, discoverability
- Command in File AND Library Plug-in Extras; quick start in Help
- Self-uninstall from the Help quick start (mac Modules installs); document disabled-state gotcha
- Azure Trusted Signing for the Windows installer via jsign
- One-command human release -- cut, gate, ship, verify, reopen

### Changed

- Single canonical location -- File > Plug-in Extras only
- Move the button to the Plug-in Manager section
- Clean is a plain rm -rf output (Yuval decision)

### Chore

- Reopen development at 0.3.0-dev

### Documentation

- PACKAGING-PLAN status — shipped as v0.2.1, v0.2.0 withdrawn
- Plug-in Extras menu screenshot for Home + pkg conclusion screen
- Menu screenshot now shows File > Plug-in Extras (single canonical location)
- Fix screenshot alt text -- File menu
- Cut-release verify list covers the six current assets + wiki sync

### Fixed

- ASCII-only ANSI NSI -- Homebrew makensis crashes on any Unicode build (NSIS bug #1165) and rejects UTF-8 script input; strings were ASCII already
- Accept any win-* Node arch in the installer payload (CI composes win-arm64)
- Clean can no longer fail on Finder .DS_Store recreation


## [0.2.1]

Fixes v0.2.0's release artifacts shipping a stale, end-of-life **Node 20** runtime: the
build's Node cache was keyed by platform only, so the v20 → v24 pin bump silently reused
old cached binaries (the mac zip even mixed a Node 20 arm64 slice with a Node 24 Intel
slice). The cache is now keyed by version, the pinned version string is asserted in every
fetched binary at build time, and CI's smoke check asserts it in every bundled binary.
The v0.2.0 release has been withdrawn — use this one; its zips genuinely ship Node
v24.18.0.

## [0.2.0]

Packaging and release-pipeline overhaul. Releases now ship **three zips** —
`SpeciesTagger-<ver>-mac.zip` (universal darwin Node only), `SpeciesTagger-<ver>-win.zip`
(`node.exe` only), and `SpeciesTagger-<ver>-all.zip` (both runtimes; the package that
single-download channels like Adobe Exchange take) — roughly halving the per-OS download.
The renamed assets also fix the Windows Extract-All experience: the wrapper folder is now
`SpeciesTagger-<ver>-win` instead of the plugin-lookalike `SpeciesTagger.lrplugin-<ver>`.
The bundled Node runtime moved off the end-of-life v20 line to the newest Active LTS
(v24.18.0), guarded by a new weekly CI check (`scripts/check-node-eol.sh`) that fails when
the pin nears EOL. CI is now validation-only — signing keys never live on GitHub;
`./release.sh` cuts and publishes the whole signed, notarized release locally in one
command (`--no-publish` for dry runs).

## [0.1.0]

Initial release. A Lightroom Classic plugin that tags the plants and animals in your
photos with both the **common** and the **Latin (scientific)** name — assisted by Google
Lens and decided by you. For each photo it opens Google Lens in a **visible** Chrome
window; you read Google's real results and **highlight** the species name, and the plugin
canonicalizes your pick through the keyless **GBIF** taxonomy backbone and writes the
keywords. It uses only the name you highlight (`window.getSelection()`) and never reads
the page, keeping it within Google's terms. Multi-photo runs reuse one Chrome window
(fresh tab each, "Photo m of n" counter, **Skip** button) and close it cleanly at the end.
The released bundle is self-contained — it ships its own Node runtime and the Lens
helper's dependencies, so end users unzip and run with no `npm install`. macOS and Windows.
