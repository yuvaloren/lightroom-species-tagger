# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/) and the project follows
[Semantic Versioning](https://semver.org/).

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
