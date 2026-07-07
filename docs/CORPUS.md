# The test corpus, query framings, and keyword scenarios

This is the plan for a thorough, reproducible regression suite: a worldwide
ground-truth corpus, real Google Lens captures under several query framings, and
the specific keyword scenarios we want the identifier to handle well.

## 1. Ground truth (open, worldwide, reproducible)

`spec/fixtures/groundtruth/worldwide.lua` — ~250 species built from public
iNaturalist research-grade observations by `scripts/build-inat-corpus.lua
--worldwide`. It sweeps **18 anchor regions across every continent and biome**
(Monterey, Sonoran Desert, Yellowstone, Monteverde, Amazon, Galápagos, Patagonia,
Andalusia, Białowieża, Serengeti, Kruger, Madagascar, Western Ghats, Borneo,
Honshu, Great Barrier Reef, Fiordland, Svalbard) **interleaved across all 10 major
taxa** (birds, mammals, reptiles, amphibians, fish, insects, arachnids, molluscs,
plants, fungi), so the corpus spans the tree of life rather than one region's
marine life.

Each record carries `scientific/genus/family` (via GBIF), a human-readable `place`
+ `lat/lng`, and — so the corpus recreates byte-for-byte — the photo `image_url`,
its `license`, and `attribution`. Images are gitignored (CC-licensed); rebuild them
from the committed data with `scripts/build-inat-corpus.lua --fetch --name worldwide`.

## 2. Query framings (how location/keywords enter the Lens search)

The plugin will prompt for **two optional fields**: *location info* and *other
identifying info*. How that text is folded into the Lens visual search is an open,
measurable question, so the framings are named strategies in
`src/shared/LensQuery.lua` and the best default is chosen from capture data, not
asserted:

| strategy        | query for place "Serengeti"      | hypothesis |
|-----------------|----------------------------------|------------|
| `none`          | *(place not added as text)*      | geolocation alone may be enough; text may derail |
| `in`            | `in Serengeti`                   | natural-language context (current default) |
| `photographed`  | `photographed in Serengeti`      | more explicit "where taken", not subject |
| `seen`          | `seen in Serengeti`              | birder phrasing |
| `bare`          | `Serengeti`                      | risk: Lens treats place as the subject |
| `location`      | `location: Serengeti`            | operator style — does Lens honor it or read "location" literally? |
| `location-info` | `location info: Serengeti`       | same question, wordier |

"Other identifying info" is prepended verbatim: `juvenile in Serengeti`.

## 3. Capture variants (checked-in regression fixtures)

Recorded to `spec/fixtures/captures/<variant>/` by `scripts/capture-corpus.lua`
(residential network + Chrome). Priority order:

1. `baseline` — pure image search (geolocation via lat/lng, **no** text). The control.
2. `loc-in` — `--use-place --strategy in`. Does the place as text help vs. baseline?
3. `loc-label` — `--use-place --strategy location`. Does the operator form help or hurt?
4. `kw-*` — the curated keyword scenarios below.

The A/B we care about: **recall / top-1 / false-positives** per variant over the
same species (`scripts/live-accuracy.lua` scores a variant's cache).

## 4. Keyword scenarios we want to handle well

Realistic things a person types, and what each stresses. The **other identifying
info** field:

| scenario            | example other-info    | stresses |
|---------------------|-----------------------|----------|
| life stage          | `juvenile`, `chick`, `nymph`, `seedling` | must not be read as a genus |
| sex                 | `male`, `female`      | short common words |
| behavior / pose     | `in flight`, `feeding`, `swimming` | multi-word, verb-y |
| size                | `about 2 inches`, `tiny` | numbers (the parser strips digit-strings) |
| color / markings    | `orange stripes`, `iridescent` | adjectives that aren't names |
| habitat             | `tide pool`, `freshwater`, `rainforest` | place-like but not a place |
| informal group      | `nudibranch`, `warbler`, `skink`, `mushroom` | the user naming the taxon themselves |

The **location** field and its traps:

| scenario            | example location      | stresses |
|---------------------|-----------------------|----------|
| plain place         | `California`, `Monterey Bay` | the common case |
| place == a species/word | `Turkey`, `Java`, `China` | must stay a place, not become the subject |
| non-English place   | `Île de la Réunion`, `Kraków` | unicode, accents |
| very long free text | a whole sentence      | the query must still be usable |
| empty               | *(blank)*             | falls back to a plain image search |

Edge cases 4a (traps) and empties are covered by **unit tests** on
`LensQuery.compose` (deterministic, no network). The life-stage / behavior /
informal-group scenarios become a small **`kw-*` capture set** over a hand-picked
subset (e.g. a juvenile bird, a nudibranch, a mushroom) so we prove the parser
still lands the species when the user adds these words — captured and committed
like the other variants.

## 5. Regression gate

`spec/accuracy_spec.lua` replays the committed captures through the real pipeline
and asserts recall / precision / genus / family per case. Adding a capture variant
or a `kw-*` scenario extends the gate automatically.
