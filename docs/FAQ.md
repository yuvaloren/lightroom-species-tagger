# FAQ

### Why Google Lens / image search instead of a vision LLM?
For species specifically, Google's reverse-image-search signal was consistently
more accurate in testing than general multimodal models. This plugin uses that
signal and then adds a real taxonomy resolver (GBIF) and a confidence model on
top, so the output is canonical names rather than free-text guesses.

### Does it cost money? Do I need an API key?
No money, and no API key for the default **Google Lens** backend — but Lens has
no anonymous API, so you paste your **browser session cookie** once (from a
browser where lens.google.com works) and the plugin uses `curl` with it
(macOS/Linux). GBIF (the taxonomy) is free and keyless. The other backends use
their own key: **Pl@ntNet** is a free key (500/day, no credit card); **Google
Vision** needs a Google Cloud project with billing enabled (a card on file;
~1,000 images/month free, then paid).

### How do I get the Lens cookie, and is it reliable?
In a browser where lens.google.com works: open DevTools → Network, run a Lens
image search, click the `upload` request, and copy its **Cookie** header value
into the plugin's **Lens cookie** setting. Re-paste when it expires. It's
**best-effort**: Google requires a genuine browser session (real cookies; even
Safari works, so it's the session, not Chrome-specific headers, that matters). A
stale cookie or a flagged/datacenter network makes the photo fall through to
**needs review** — it never crashes or double-tags. If you hit this often, use
Pl@ntNet (plants) or Vision.

### Lens vs Pl@ntNet vs Vision — which should I use?
- **Lens (direct):** free, no key, broad coverage (plants + animals), closest to
  the Lens app; best-effort reliability.
- **Pl@ntNet:** free key, extremely reliable, **plants only** — ideal if you shoot
  flora.
- **Vision:** the most reliable, ToS-clean option and broad coverage, but it
  requires a Google Cloud billing account (card on file). Pick it if that's
  acceptable and you want maximum dependability.
You can switch anytime in settings; the rest of the pipeline is identical.

### Why does it sometimes pick an odd common name?
The scientific (Latin) name is always GBIF's accepted name. The common name comes
from what the image search surfaced when available, otherwise from GBIF's
vernaculars — which occasionally aren't the most familiar one. The Latin name is
the unambiguous anchor; rename the common keyword if you prefer another.

### Why GBIF for the names?
GBIF's backbone is free, keyless, and authoritative. It turns a messy web label
into the **accepted** scientific name, gives a **preferred common name**, and
provides the full **Kingdom→Species** classification used for hierarchy keywords.

### Why both common and Latin names?
Common names are searchable and human-friendly; Latin names are unambiguous and
stable across languages and regions. Storing both makes your catalog findable now
and correct later.

### Will it tag two animals in one photo?
Yes — every species that clears the confidence threshold is tagged. Some frames
only surface the dominant subject; crop and re-run for the rest.

### How do I know it's accurate / won't regress?
Run `just accuracy` for a report over the labelled fixture corpus, and
`just test` for the full suite. CI runs both on every push. Add your own photos
to the corpus with `scripts/record-fixture.lua`.

### It mislabelled something — what should I do?
Lower or raise the **Auto-apply** threshold to taste, and record a fixture for
the bad case so it can be reproduced and the heuristics tuned. Identification is
a fast first pass, not a substitute for an expert on tricky look-alikes.
