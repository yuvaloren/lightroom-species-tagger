# Roadmap

Where this project is headed. It's a focused tool — the bar for a new item is that it
makes tagging more accurate, more honest, or easier to run, without turning the plugin
into a kitchen sink. Ideas and PRs welcome (see [CONTRIBUTING.md](CONTRIBUTING.md)); open
a [feature request][fr] to discuss.

[fr]: https://github.com/yoren/lightroom-species-tagger/issues/new?template=feature_request.yml

## Near-term

- **Cut the first tagged release (v0.1.0).** The release automation (version-drift guard,
  git-cliff notes, checksummed zip) is built and CI-wired but not yet exercised end to
  end. See [CONTRIBUTING.md → Releasing](CONTRIBUTING.md#releasing).
- **README screenshot / short GIF** of the assistive flow in Lightroom — the Lens window
  with the bottom Tag bar and the resulting keywords — so first-time users and reviewers
  see the product, not just prose.

## Ideas

- **Multi-photo ergonomics.** A keyboard shortcut to Tag the current selection, and a
  clearer "done / next" affordance, so a batch flows without reaching for the mouse.
- **An optional official-API backend.** For fully hands-off tagging, a backend that uses
  an official image-recognition API with the user's own key (e.g. Google Cloud Vision, or
  Pl@ntNet for plants) could auto-suggest a name the user confirms — trading the assistive
  UX for automation, at the cost of a key/billing. Additive; doesn't change the core.

## Distribution

- **Adobe Exchange listing (now more viable).** The assistive design does no scraping, so
  the main ToS objection is gone; the remaining risk is environment-dependence (Node +
  Chrome must be set up for a reviewer). GitHub Releases stays the primary channel. Full
  analysis in [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).
- **Community directory listings** (Lightroom Queen, Adobe's plug-ins pointer page) for
  discovery once there's a tagged release to point at.

## Done (recent highlights)

The assistive pivot: the plugin opens Google Lens in a visible window, you highlight the
species and press Tag, and it resolves your pick through the open GBIF API and writes the
keywords — no scraping, no automated extraction, so it stays within Google's terms. One
reused window across photos with an "m of n" counter and a clean shutdown; cross-platform
Node/Chrome discovery. See [CHANGELOG.md](CHANGELOG.md) for the full history.
