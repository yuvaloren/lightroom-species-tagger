---
name: cut-release
description: Cut a tagged release of the plugin without tripping the CI version-drift guard, then publish it locally with release.sh. Use when shipping a new version, bumping VERSION, or when asked to "release", "tag a version", or "publish a release".
---

# Cut a release

Releases are **published locally by `./release.sh`** (sign + notarize + package +
`gh release create`) — CI is validation-only and never signs or publishes (no signing
secrets on GitHub; see docs/SIGNING.md). CI still enforces that three things agree on a
`v*` tag — the git tag, the `VERSION` file, and a `CHANGELOG.md` heading. This skill does
the steps in the order that never trips that guard.

## Pre-flight

```bash
just check                              # lint + tests + build must be green
```

Confirm the `build` and `lens-helper` CI jobs are green on the commit you're tagging —
a red Lens test means the release ships broken code. Don't work around it; fix the test.

## Steps

1. **Choose the version** (SemVer: `MAJOR.MINOR.PATCH`).
2. **Bump `VERSION`** to exactly that string (drop the `-dev` suffix used during
   development):
   ```
   0.2.0
   ```
3. **Check the CHANGELOG heading.** A `## [0.2.0]` heading must exist (it's usually
   written during development); finalize its text. CI greps for the exact heading.
4. **Sanity-check the three agree** (this is exactly what CI's drift guard checks):
   ```bash
   test "$(tr -d '[:space:]' < VERSION)" = "0.2.0" && echo "VERSION ok"
   grep -q '## \[0.2.0\]' CHANGELOG.md && echo "CHANGELOG heading ok"
   ```
5. **Commit** with a conventional message, then **tag and push**:
   ```bash
   git add VERSION CHANGELOG.md
   git commit -m "chore(release): v0.2.0"
   git tag v0.2.0
   git push && git push --tags
   ```
6. **Wait for CI to go green on the tag** (build + lens-helper + the drift guard), then
   **publish from the Mac**:
   ```bash
   ./release.sh                # sign + notarize + package + publish the GitHub Release
   ```
   `--no-publish` builds everything without creating the Release (dry run).
   release.sh refuses to publish a `-dev` VERSION, an unsigned build, or a tag that
   isn't at HEAD.
7. **After publishing, reopen development**: bump `VERSION` to the next `X.Y.Z-dev`
   in a follow-up commit.

> Tagging + pushing is a maintainer action and irreversible on a public remote —
> only do it when explicitly asked, and never invent a version.

## Verify after

- The Release exists with **four assets**: `SpeciesTagger-<ver>-mac.zip`,
  `SpeciesTagger-<ver>-win.zip`, `SpeciesTagger-<ver>-all.zip`, `checksums.txt`.
- The README "Install (from a release)" download link resolves.
- CI on the tag is fully green (it validates; it does not publish).

If the drift guard failed the build, the tag, `VERSION`, and CHANGELOG heading disagree —
fix them, delete the bad tag (`git tag -d v0.2.0 && git push --delete origin v0.2.0`),
and redo from step 4.
