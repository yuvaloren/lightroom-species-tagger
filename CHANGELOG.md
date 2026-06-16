# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/) and the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial release. A Lightroom Classic plugin that identifies plants and animals
  in selected photos with an image-recognition backend and tags them with both
  the **common** and **Latin (scientific)** name.
- Three interchangeable recognition backends behind a provider seam, all sending
  image bytes directly (no third-party image host):
  - **Google Lens (direct)** — the default; **free, no API key**. Talks to Google
    Lens like a browser and harvests names from the results page. Best-effort:
    degrades gracefully (a photo goes to *needs review*) if Google blocks/rate-limits.
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
