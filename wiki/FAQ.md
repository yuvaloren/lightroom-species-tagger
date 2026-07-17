# FAQ

### Why Google Lens instead of a vision LLM?
For species specifically, Google Lens's reverse-image-search results were consistently
the most useful signal in testing. Here you read those results yourself and pick the
species; the plugin then turns your pick into canonical names via GBIF.

### Does it cost money? Do I need an API key?
No money, and **no API key for anything**. Google Lens is keyless and GBIF (the taxonomy)
is free and keyless. You only need **Google Chrome** installed, because the plugin opens
Lens in your real Chrome. The released bundle is self-contained — recognition is
driven by a small native helper (~6 MB) bundled inside; there is nothing to install
beyond Chrome.

### How accurate is it?
It's as accurate as the name **you** pick. The plugin doesn't guess — it shows you
Google's real results and you highlight the species; GBIF then resolves that to the
accepted Latin name, preferred common name, and classification. Run it from a normal home
(residential) connection — Google challenges datacenter/VPN/shared IPs. A photo you don't
tag is simply left untouched.

### Does it run on Windows?
Yes — **macOS and Windows** are both supported (x64 and ARM64 on both). The Lens
helper locates your installed Chrome automatically.

### Can I add keywords to the search?
Yes — use **Google's own search box** on the Lens page to add words (`juvenile`, `reef`) or
crop, then highlight the species and press Tag. (The plugin doesn't add a keyword box of
its own.)

### Can I correct a wrong pick without re-shooting?
Yes — nothing is read until you press Tag, so if you tagged the wrong thing, just highlight
the right name and press Tag again. To remove an incorrect keyword, delete it from
Lightroom's Keyword List.

### How does it decide which species to tag?
It doesn't — **you** do. It reads only the text you highlight and hands that one string to
GBIF. There's no confidence score or auto-guessing; the identification is yours.

### Why does it sometimes pick an odd common name?
The scientific (Latin) name is always GBIF's accepted name. The common name comes from
GBIF's vernaculars, which occasionally aren't the most familiar one. The Latin name is the
unambiguous anchor; rename the common keyword if you prefer another.

### Why GBIF for the names?
GBIF's backbone is free, keyless, and authoritative. It turns whatever you highlight (a
common name or a binomial) into the **accepted** scientific name, a **preferred common
name**, and the full **Kingdom→Species** classification used for hierarchy keywords.

### Why both common and Latin names?
Common names are searchable and human-friendly; Latin names are unambiguous and stable
across languages and regions. Storing both makes your catalog findable now and correct
later.

### Can I tag two animals in one photo?
Yes — highlight one, press Tag, then highlight the other and press Tag again before moving
on. Both keywords are applied to the photo.

### How do I know a change didn't break it?
`just check` runs luacheck + the offline unit tests + the build, and `just lens-test`
drives the real Lens helper against a fake Google. CI runs them on every push. The live
browser flow itself is verified by hand in Lightroom (it can't be exercised offline).
