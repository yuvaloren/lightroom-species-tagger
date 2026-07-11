# Distribution channels

How Species Tagger reaches users beyond the GitHub release page. The GitHub
release (installers + zips, built by `./release.sh`) stays the canonical
source; everything below points back to it or repackages its artifacts.

## Adobe Exchange (Creative Cloud marketplace)

Lightroom Classic plugins are listed on the [Creative Cloud
marketplace](https://exchange.adobe.com/apps/browse/cc?product=LTRM) via the
[Adobe Developer Distribution
portal](https://developer.adobe.com/developer-distribution/). Since Creative
Cloud desktop 5.8 (July 2022) the CC app installs LrC plugins itself, driven
by an `.mxi` manifest inside the package — details in [Adobe's announcement
post](https://blog.developer.adobe.com/lightroom-classic-plugin-support-for-the-adobe-exchange-for-creative-cloud-14e4a0f690df).

### The package

```
just exchange-zip            # or: bash scripts/build-exchange-zip.sh [X.Y.Z]
```

produces `output/dist/SpeciesTagger.zip`:

```
SpeciesTagger.zip
├─ SpeciesTagger.lrplugin/   # payload of the released -all zip, verbatim
└─ SpeciesTagger.mxi         # install manifest: .lrplugin → $modules
```

- Payload comes FROM the released `SpeciesTagger-<ver>-all.zip` (downloaded
  from the GitHub release when not in `output/dist`) — single source of
  packaging truth, same pattern as the pkg/exe installers. Binaries inside are
  already Developer ID signed + notarized.
- `$modules` is Adobe's token for the per-user auto-load Modules folder on
  both OSes — the same folder the pkg/exe installers target, so LR de-dupes
  cleanly (same `LrToolkitIdentifier`) if a user has both.
- Adobe's naming rule: mxi basename == package basename == mxi `id`
  (`SpeciesTagger`). The package name is unversioned; the version lives in the
  mxi.
- Exchange also accepts signed ZXPs. We submit the plain zip; if review asks
  for a ZXP, add a `ZXPSignCmd` step to `scripts/build-exchange-zip.sh`.

### Submitting (one-time setup, then per-release)

1. One-time: sign in at
   [developer.adobe.com/developer-distribution](https://developer.adobe.com/developer-distribution/)
   with the Adobe ID, create the **publisher profile** (public name, logo,
   description) and wait for its approval. EU visibility requires trader
   details (Digital Services Act) — a free listing can opt out of EU
   distribution instead.
2. Create a Creative Cloud **listing**: metadata + media (icon, screenshots),
   upload `SpeciesTagger.zip` as the version package, submit for review.
3. Per release afterwards: `just exchange-zip`, upload as a new version with
   release notes (from CHANGELOG.md), resubmit.

Adobe contacts: `ccintrev@adobe.com` for build/upload/review issues,
`asupport@adobe.com` for user-side install problems.

### Listing assets

Live in the Exchange portal, not in this repo. Current gaps and sources are
tracked in the private planning folder (`../distribution/` relative to this
repo in Yuval's PhotoManagement project folder) — listing copy, icon,
screenshot shot-list.

## Other channels

- **GitHub Releases** — canonical; evergreen links
  `releases/latest/download/SpeciesTagger-{mac.pkg,win-setup.exe}`.
- **The Lightroom Queen** [plug-ins
  directory](https://www.lightroomqueen.com/links/plugins/) — hand-curated by
  Victoria Bampton; listing happens by asking (contact form).
- **Community announcements** — Adobe Community (Lightroom Classic),
  r/Lightroom, the iNaturalist forum (nature-photography keywording is the
  core audience).
- **Press/blogs** — Lightroom Killer Tips, PetaPixel, Fstoppers, etc.

Outreach drafts and status live in the private planning folder, not here.
