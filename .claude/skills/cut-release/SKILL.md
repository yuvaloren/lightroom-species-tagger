---
name: cut-release
description: Cut a tagged release of the plugin without tripping the CI version-drift guard. Use when shipping a new version (e.g. the first v0.1.0), bumping VERSION, or when asked to "release", "tag a version", or "publish a release".
---

# Cut a release

Releases are fully automated on a `v*` tag, but CI enforces that three things agree —
the git tag, the `VERSION` file, and a `CHANGELOG.md` heading. This skill does the
steps in the order that never trips that guard.

## Pre-flight

```bash
just check                              # lint + tests + build must be green
```

Confirm the `lens-helper` CI job is green on the commit you're tagging — the release
job is gated on it (`needs: [build, lens-helper]`), so a red Lens test blocks the
release by design. Don't work around that; fix the test.

## Steps

1. **Choose the version** (SemVer: `MAJOR.MINOR.PATCH`). For the first real release
   that's `0.1.0`.
2. **Bump `VERSION`** to exactly that string (no `-dev`):
   ```
   0.1.0
   ```
3. **Add a matching CHANGELOG heading.** Rename `## [Unreleased]` to
   `## [0.1.0] - YYYY-MM-DD` (keep an empty `## [Unreleased]` above it for next time).
   The heading text `## [0.1.0]` must be present — CI greps for it.
4. **Sanity-check the three agree** (this is exactly what CI's drift guard checks):
   ```bash
   test "$(tr -d '[:space:]' < VERSION)" = "0.1.0" && echo "VERSION ok"
   grep -q '## \[0.1.0\]' CHANGELOG.md && echo "CHANGELOG heading ok"
   ```
5. **Commit** with a conventional message, then **tag and push**:
   ```bash
   git add VERSION CHANGELOG.md
   git commit -m "chore(release): v0.1.0"
   git tag v0.1.0
   git push && git push --tags
   ```

> Tagging + pushing is a maintainer action and irreversible on a public remote —
> only do it when explicitly asked, and never invent a version. If there's no GitHub
> remote yet, stop after the commit and hand the tag step to the maintainer.

## What CI does on the tag (verify after)

On the `v0.1.0` tag the `release` job (only if `build` and `lens-helper` are green):
version-stamps the bundle, zips it, writes `checksums.txt`, generates notes with
git-cliff, and publishes a GitHub Release with the zip attached. After it runs, confirm:

- The Release exists with the `SpeciesTagger.lrplugin-0.1.0.zip` + `checksums.txt` attached.
- The README "Install (from a release)" download link now resolves.

If the drift guard failed the build, the tag, `VERSION`, and CHANGELOG heading disagree —
fix them, delete the bad tag (`git tag -d v0.1.0 && git push --delete origin v0.1.0`),
and redo from step 4.
