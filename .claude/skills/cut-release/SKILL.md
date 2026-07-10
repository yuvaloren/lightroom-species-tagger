---
name: cut-release
description: Cut and publish a tagged release of the plugin. Use when shipping a new version, bumping VERSION, or when asked to "release", "tag a version", or "publish a release".
---

# Cut a release

The whole release is ONE human-runnable command — no AI required:

```bash
./release.sh                    # release VERSION-minus--dev (e.g. 0.3.0-dev -> 0.3.0)
./release.sh --version=0.4.0    # minor/major jump instead
```

It does, in order: pre-flight (clean tree on main, synced, gh authed) → write
`VERSION` → reuse the hand-written `## [X.Y.Z]` CHANGELOG section or generate
it from conventional commits (git-cliff) → lint + tests → the full artifact
pipeline (sign + notarize + zips + stapled pkg + Windows installer) → **one
y/N confirmation** → commit + tag + push → wait for CI green on the tag →
`gh release create` with the six assets → wiki sync → verify the evergreen
download links → reopen development at `X.Y.(Z+1)-dev`.

Nothing irreversible happens before the confirmation; CI is validation-only
and never signs or publishes (no signing secrets on GitHub — docs/SIGNING.md).

`--no-publish` is the dry run (build the current tree, no bump/tag/publish);
`--yes` skips the confirmation for unattended runs.

## If something fails

- **Before the y/N prompt** (lint, tests, build, notarization): nothing was
  committed or pushed. `VERSION`/`CHANGELOG.md` edits may sit in the working
  tree — `git checkout -- VERSION CHANGELOG.md` discards them. Fix and re-run.
- **CI gate red after the tag push**: fix the problem, then
  ```bash
  git tag -d vX.Y.Z && git push --delete origin vX.Y.Z
  ```
  and re-run `./release.sh` (the release commit is already on main; pass
  `--version=X.Y.Z` since VERSION no longer ends in -dev).
- **After publish** (verify/reopen steps): the Release is live; finish the
  remaining steps by hand (`printf 'X.Y.Z+1-dev\n' > VERSION`, commit
  `chore: reopen development at …`, push).

## Verify after

- The Release shows **six assets**: `SpeciesTagger-mac.pkg` and
  `SpeciesTagger-win-setup.exe` (unversioned names — the wiki's evergreen
  `releases/latest/download/` links depend on them), plus
  `SpeciesTagger-<ver>-mac.zip`, `SpeciesTagger-<ver>-win.zip`,
  `SpeciesTagger-<ver>-all.zip`, `checksums.txt`.
  (release.sh's verify stage asserts all of this automatically.)
- The wiki's two Download buttons resolve.
- CI on the tag is fully green.

> Tagging + pushing is a maintainer action and irreversible on a public
> remote — only release when Yuval explicitly asks, and never invent a version.
