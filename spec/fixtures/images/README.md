# Test images

Original photos for **live** recording / accuracy runs go here. They are
git-ignored on purpose (they're your own photos, often large), so the offline
test suite never depends on binary blobs — it replays the recorded JSON in
`../lens` and `../gbif` instead.

To enable live mode for a case in `../manifest.lua`, drop the matching file here
using the `image` field as the filename, e.g.:

    spec/fixtures/images/reef_octopus_triggerfish.jpg

Then record real Lens + GBIF fixtures:

    lua scripts/record-fixture.lua spec/fixtures/images/reef_octopus_triggerfish.jpg

Or build a whole open, reproducible corpus (with images) from iNaturalist:

    lua scripts/build-inat-corpus.lua --n 40
