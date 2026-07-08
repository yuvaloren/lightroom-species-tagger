<!--
Thanks for contributing! Keep PRs small and focused — one change per PR is easiest
to review and revert. Everything below maps to CONTRIBUTING.md; if a box doesn't
apply, say so rather than deleting it.
-->

## What & why

<!-- One or two sentences: what does this change, and why? Link any issue: "Fixes #123". -->

## The gate

Run the same gate CI runs — paste the result or tick the box:

- [ ] `just check` is green (lint + tests + build). No `just`? Run `luacheck src spec scripts`, `busted`, and `lua build/build.lua`.
- [ ] `luacheck` reports **0 warnings** (the standard).

## If you changed logic

- [ ] The change lives in a **pure module** (`src/shared/`) where it can, with I/O still injected via `deps` (no direct network/Lightroom calls in the pure layer).
- [ ] I added or updated a **spec** in `spec/` (pure functions get white-box tests via the module's `_test` table).

## If you touched the Lens helper or added test fixtures

- [ ] Node helper changes are covered by `scripts/lens/test/integration.test.js` (the real helper vs a local fake Google, headless, no network) — run `just lens-test`.
- [ ] The suite uses **no real photos**; any new fixture is small, impersonal, and open-licensed/synthetic — **no personal photos, EXIF, accounts, or tokens** (see CONTRIBUTING.md → *Privacy & scope for test data*).

## Housekeeping

- [ ] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, …).
- [ ] I updated docs/README/CHANGELOG if this changes behavior a user would notice.

## Notes for the reviewer

<!-- Anything worth flagging: trade-offs, follow-ups, things you're unsure about. -->
