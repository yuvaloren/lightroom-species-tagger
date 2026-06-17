# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/) and the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial release. A Lightroom Classic plugin that identifies plants and animals
  in selected photos with an image-recognition backend and tags them with both
  the **common** and **Latin (scientific)** name.
- Three interchangeable recognition backends behind a provider seam:
  - **Google Lens** — the default; **free, no API key**. Lens has no API and
    renders results with JavaScript, so the plugin drives the user's installed
    Google Chrome (headless, via the bundled Node helper `scripts/lens`) to run a
    Lens image search and harvests the match text. Needs Node + Chrome (macOS/Linux);
    best-effort (a photo goes to *needs review* on any failure). Real-accuracy
    measurement via `just live-accuracy`; the offline corpus is representative.
  - **Pl@ntNet** — free key, plants only, very reliable.
  - **Google Vision (Web Detection)** — broad coverage; requires a GCP billing account.
- Keyless taxonomy resolution + normalization via the **GBIF** backbone, with
  optional full taxonomic-hierarchy keywords (Kingdom → … → Species) and the
  common name attached as a keyword synonym. When the recognition signal surfaces
  a common name, it is preferred over GBIF's arbitrary first vernacular.
- Confidence-scored results with an **auto-apply-if-confident** policy; uncertain
  photos get a `species: needs review` keyword instead of a guess.
- Offline, deterministic **accuracy + regression harness**: a labelled fixture
  corpus (seeded from real @yuvalsaw photos across fish, invertebrates, marine &
  terrestrial mammals and birds), `scripts/accuracy.lua` reporting
  top-1 / recall / genus / family, `scripts/record-fixture.lua` to capture real
  fixtures from live images, and `scripts/build-corpus.lua` to (re)build the corpus.
