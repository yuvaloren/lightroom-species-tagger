# Checked-in Google Lens capture corpus

These are **real Google Lens responses** recorded for the open ground-truth corpus
(`spec/fixtures/groundtruth/worldwide.lua`, built from public iNaturalist
research-grade observations). They are the durable regression set for the
parser → GBIF → scorer pipeline: deterministic, offline-replayable, and public.

## Layout

```
captures/<variant>/<image>.json
```

Each `<variant>` is one way of adding the location / keyword hint to the visual
search, captured separately so we can measure which framing identifies species
best (see `src/shared/LensQuery.lua` for the framings and `docs/SCORING.md`):

- `baseline/`   — pure image search, no text hint.
- `loc-in/`     — location added as `in <place>` (the current default framing).
- `loc-label/`  — location added as `location: <place>` (operator style).
- `kw-*/`       — curated keyword scenarios we want to handle well.

Each file is self-contained:

```json
{ "image": "inat_123.jpg", "scientific": "Mirounga angustirostris",
  "genus": "…", "family": "…", "place": "Monterey Bay, California, USA",
  "variant": "loc-in", "strategy": "in", "query": "in Monterey, California, USA",
  "overview": "<Google AI Overview text>", "strings": [ "<visible match titles>" ] }
```

## How these are made / recreated

1. Build the ground truth + fetch images (open iNaturalist + GBIF, any network):
   `lua scripts/build-inat-corpus.lua --worldwide`
   (or recreate images from the committed data: `--fetch --name worldwide`).
2. Capture Lens output per variant (residential network + Chrome required — Google
   blocks datacenter IPs):
   `lua scripts/capture-corpus.lua --groundtruth fixtures.groundtruth.worldwide --variant baseline --limit 40`

## Provenance & licensing

The **species/taxonomy** come from GBIF; the **images** are CC-licensed
iNaturalist photos — we record each photo's URL, licence, and attribution in the
groundtruth and **do not** commit the image bytes (`spec/fixtures/images/` is
gitignored). What is committed here is the **text** of Google's results page
(AI-overview sentence + visible match titles) for a public research image — the
same kind of representative data already in `spec/fixtures/lens/`.
