# FAQ

### Why Google Lens / image search instead of a vision LLM?
For species specifically, Google's reverse-image-search signal was consistently
more accurate in testing than general multimodal models. This plugin uses that
signal and then adds a real taxonomy resolver (GBIF) and a confidence model on
top, so the output is canonical names rather than free-text guesses.

### Does it cost money? Do I need an API key?
The default **Google Lens (direct)** backend is **free and needs no key** — it
talks to Google Lens the way the website does. GBIF (the taxonomy) is free and
keyless too. The optional backends need their own (free or paid) key: **Pl@ntNet**
is a free key (500/day, no credit card); **Google Vision** needs a Google Cloud
project with billing enabled (a card on file; ~1,000 images/month free, then
paid). You bring your own keys for those.

### Is the free Google Lens backend reliable?
It's **best-effort**. There is no official Google Lens API, so the backend
uploads your image like a browser and parses the results page. From a normal home
(residential) connection, occasional batches generally work. But Google actively
discourages automated access and may respond with a consent wall, a CAPTCHA, or a
rate-limit — especially from shared, VPN, or datacenter networks. When that
happens the plugin reports it and the photo goes to **needs review**; it never
crashes or double-tags. If you hit blocks often, use Pl@ntNet (plants) or Vision.

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
