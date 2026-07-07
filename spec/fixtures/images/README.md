# Test images

This directory is a placeholder for local test photos. Any images you drop here are
**git-ignored** on purpose — they're your own photos, often large, and may carry personal
EXIF. The offline test suite never depends on them: it replays the recorded GBIF JSON in
`../gbif` instead.

You'd only put an image here to try the Lens helper by hand, e.g.:

    node scripts/lens/lens-search.js spec/fixtures/images/my-photo.jpg
