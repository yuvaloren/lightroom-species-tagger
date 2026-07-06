# Scoring & confidence — what the number means

Short version: **the confidence is a bounded *evidence score*, not a calibrated
probability.** A `0.62` does not mean "62% of tags like this are correct." It's a
transparent, monotonic score that rises with how much mutually-agreeing evidence
supports a taxon, squashed into `(0, 1)` so a single threshold works as an operating
point. This page explains exactly how it's computed, why it's honest to call it a
heuristic, and how to ground the threshold in real data.

## How a taxon is scored

All of this lives in [`src/shared/Identify.lua`](../src/shared/Identify.lua) and is
unit-tested. For each name candidate the parser found and GBIF confirmed:

```
contribution = candidate.score
             * kindFactor[kind]        -- a confirmed binomial (2.0) > a common name (1.0)
             * matchFactor[matchType]  -- EXACT (1.0) > FUZZY (0.8) > HIGHERRANK (0.4)
             * rankFactor[rank]        -- species/subspecies (1.0) > genus (0.5)

finalSupport = sum(contributions over all candidates that resolved to this taxon)
             * agreementBonus          -- ×1.3 if BOTH a scientific and a common
                                       --   candidate independently resolved here

confidence   = finalSupport / (finalSupport + squashK)   -- squashK = 2.0
```

The squash is a standard `x / (x + k)` saturating curve: more support → higher
confidence, with diminishing returns, always strictly below 1. The core signal is
**agreement** — when an independent scientific name *and* an independent common name
land on the same species, that's much stronger than either alone.

A taxon only **auto-applies** when it clears the threshold *and* has enough support
*and* is either a confirmed binomial or a strongly-recurring common name — and, when
Lens gave an authoritative AI-Overview answer, is one the Overview actually named
(this is what suppresses the many binomial-bearing look-alikes Lens surfaces). That
gate is one function, [`Identify.confidentAt`](../src/shared/Identify.lua), shared by
the live plugin and the calibration sweep below, so a swept threshold means exactly
what the plugin will do.

## Why it's honest to call it a heuristic

The weights above (`2.0`, `1.0`, `0.8`, `1.3`, `squashK = 2.0`) are **hand-chosen so
the ordering is sensible**, not fitted to a labelled dataset. Nothing here was
regressed against "score vs. actually-correct" pairs. So:

- The **ranking** is meaningful: higher confidence = more corroborated evidence.
- The **absolute value is not a probability.** Don't read `0.62` as a percentage.
- The default threshold (`0.62`) is a reasonable starting operating point, not a
  proven optimum.

Calibrating the number into a true probability would require a large set of
`(score, correct?)` pairs from **real** Lens output — and real Lens is
non-deterministic and needs a residential network, so it can't be captured
reproducibly in CI. Rather than fake a calibration, the plugin is transparent about
what the number is and gives you the tool to tune the threshold on your own data.

## Grounding the threshold in your data — the calibration sweep

Capture real Lens output for a labelled set once, then sweep:

```
# 1) one-time: capture real Lens output for a ground-truth corpus (residential network)
just capture

# 2) any time, offline: replay it and print precision/recall at every threshold
just live-accuracy -- --sweep
```

The sweep replays the cached captures through the real pipeline and, for each
candidate threshold from 0.30 to 0.95, reports:

```
threshold   precision recall    tags    correct false+
0.55        0.86      0.74      50      43      7
0.60        0.90      0.70      44      40      4
0.65        0.93      0.64      38      36      2
...
```

- **precision** = correct auto-tags ÷ all auto-tags (raise the threshold to buy
  precision — fewer wrong tags).
- **recall** = expected species recovered ÷ all expected (lower the threshold to buy
  recall — fewer photos left for review).

Pick the threshold whose precision/recall trade-off you want and set it as
**Auto-tag confidence** in the plugin settings. That's the whole point: the threshold
is yours to choose against evidence, not a magic constant.

## Growing the corpus (bigger, more reliable calibration)

A sweep is only as trustworthy as the corpus behind it. Two ways to grow it, both
from open, reproducible sources — nothing tied to any person:

- `lua scripts/build-inat-corpus.lua --n 40` pulls research-grade
  [iNaturalist](https://www.inaturalist.org/) observations (community-verified,
  open-licensed) for a region and resolves them through GBIF, writing a ground-truth
  set + downloading the images.
- `lua scripts/record-fixture.lua <image>` records a real Lens + GBIF fixture from one
  of your own photos and prints a manifest stub to paste in.

More labelled species → a more meaningful precision/recall curve → a threshold you can
actually trust.
