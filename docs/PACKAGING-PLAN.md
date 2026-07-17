# Plan: Release packaging + CI health for Species Tagger — v0.2.0

> **Superseded in part (2026-07-17):** the bundled **Node runtime described
> below was replaced by a single static Go binary** (`helper/`, ~6 MB per
> platform — see `helper/README.md` and `docs/ARCHITECTURE.md`). The
> packaging/installer *mechanics* here (zip variants, pkg/NSIS flow, signing
> split) still stand; read every mention of `node/<os-arch>/node[.exe]` as
> `helper/<key>/lens-helper[.exe]`, and size figures are ~10-40x smaller.


*Planning doc — 2026-07-09, rev 2 (incorporates Yuval's feedback). Companion to
[INSTALLERS-PLAN.md](INSTALLERS-PLAN.md). All of this ships as **v0.2.0** (dev label
`0.2.0-dev` while in progress).*

> **Status: SHIPPED as v0.2.1** (v0.2.0 was published and withdrawn the same day — its
> zips carried a stale EOL Node 20 because the build's Node cache was keyed by platform
> only and survived the pin bump; fixed in e9de8cb with a version-keyed cache plus
> version-string assertions at build time and in CI's smoke check). All verification
> passed: per-zip runtime checks, both notarizations Accepted, Windows Extract-All +
> install on the VM, and the browser-download Gatekeeper test (`gatekeeper-ok v24.18.0`,
> universal binary, quarantined). Observation: puppeteer-core 25 no longer ships bare-*
> native prebuilds, so the bundled Node is currently the only Mach-O — the prebuild
> pruning stays as belt-and-braces.*

## The five issues

1. **The release zip is big (97 MB)** — every user downloads *both* OSes' Node runtimes.
2. **No install instructions inside the zip.**
3. **Extra directory level on Windows** when extracting with Explorer's "Extract All".
4. **CI: "Node.js 20 is deprecated" warnings** on every job — and the *bundled* Node 20
   runtime is itself past end-of-life. Includes a prevention plan so it can't recur.
5. **CI: the `notarize-macos` job fails** on tags — it depends on signing secrets that
   will NOT be added to GitHub. CI stops testing signing.

## Issue 1 — Per-platform zips (build all three) ✅ direction decided

**Exchange context (researched):** Adobe Exchange takes **one package per listing version**
(ZIP, or ZXP for one-click install via the Creative Cloud desktop app) — no per-OS download
selection; platform coverage is declared in submission metadata. Since we **will** be
submitting to Exchange, the combined package is a first-class artifact, not an on-demand one.

**Plan — every release builds and publishes all three:**

- `SpeciesTagger-<ver>-mac.zip` — universal darwin Node only, darwin-only native prebuilds (est. ~65 MB)
- `SpeciesTagger-<ver>-win.zip` — `node.exe` only, win32-only prebuilds (est. ~30 MB)
- `SpeciesTagger-<ver>-all.zip` — both runtimes (the Exchange package; ~97 MB)

Mechanics: compose and sign the full bundle once (pipeline unchanged), then prune
per-platform copies at packaging time and zip each. Pruning after signing is safe — each
Mach-O is signed individually; there is no bundle-level signature. Notarize the `-mac` and
`-all` zips (they contain mac binaries); the `-win` zip needs none (`node.exe` is
Authenticode-signed by the OpenJS Foundation). `resolveNode` picks the bundled Node by file
existence — no plugin code change. `checksums.txt` covers all three. The GitHub release and
the README install section say which zip to pick (mac / win / both-OS).

## Issue 2 — Install instructions: on GitHub, not in the zip ✅ decided (tentative)

**Validation (as requested):** Exchange-distributed LrC plugin packages do **not** carry
readmes. Adobe's own packaging example for an Exchange LrC plugin contains only the plugin
files plus the `id.mxi` install manifest (`info.lua`, script, preset, `id.mxi` — no readme),
and ZXP packages are installed *automatically* by the Creative Cloud desktop app — the user
never opens the package, so an in-package readme would never be seen. Install guidance on
Exchange lives in the **listing page**, not the package. Our equivalent: instructions live
in the GitHub README + release notes.

**Plan:** no `README.txt` inside the zips (keeps them Exchange-norm-clean and keeps macOS
single-entry flat extraction — see issue 3). Instead:

- README.md install section rewritten for the three assets: which zip to download, and the
  exact extract → Plug-in Manager ▸ Add steps per OS, including the Windows wrapper-folder
  note.
- Release notes template links straight to that section.

*(Tentative per Yuval — if real-user confusion shows up later, an in-zip README.txt is a
5-line packaging change away.)*

## Issue 3 — The Windows extra directory level ✅ approved

Explorer's "Extract All" *always* wraps extraction in a folder named after the zip; that
can't be disabled from our side. The zip itself has only one level
(`SpeciesTagger.lrplugin/` at the root). What changes:

- **Rename the assets:** `SpeciesTagger-<ver>-mac.zip` / `-win.zip` / `-all.zip` — dropping
  `.lrplugin` from the zip name, so the Windows wrapper becomes `SpeciesTagger-0.2.0-win\`
  instead of the plugin-lookalike `SpeciesTagger.lrplugin-0.1.0\`.
- With no README.txt at the zip root (issue 2), the zip keeps a single top-level entry —
  macOS Archive Utility continues to extract flat (no wrapper), unchanged from today.
- README.md install steps state the extracted layout explicitly for Windows: "open the
  extracted `SpeciesTagger-<ver>-win` folder and Add the `SpeciesTagger.lrplugin` folder
  inside it."

## Issue 4 — Node 20: fix it, and make sure it can't happen again

### How we got here (root cause)

Node 20 reached end-of-life on **2026-04-30**. The Lens helper and bundle were built in
June 2026 with `NODE_VERSION = v20.20.2` — i.e. the pin was **already EOL on the day it was
written**. Two failures compounded:

1. **Process:** the version was chosen from familiarity ("Node 20 LTS") without checking
   the official support schedule at pin time.
2. **Tooling gap:** nothing watches a *custom* pin. Dependabot covers `package.json` and
   GitHub Actions (it correctly caught the actions bumps — PR #1), but `NODE_VERSION` in
   `build.lua` and `.nvmrc` are invisible to it. No alarm ever fires.

The Actions-runtime warnings are the same class: pinned action majors (`checkout@v4`,
`setup-node@v4`, …) target the Node 20 action runtime GitHub deprecated in late 2025.
Dependabot did its job there — the PR just hadn't been merged.

### Fix (now)

- Merge **Dependabot PR #1** (all 8 actions → Node-24-native majors; its CI is green.
  Caveat: the tag-gated jobs didn't run on the PR — moot anyway, since issue 5 removes them)
  and **PR #2** (puppeteer-core 23.11.1 → 25.3.0).
- Bump the project's Node to the **latest Node 24 LTS release** (Active LTS, currently
  24.18.0; Node 26 isn't LTS until Oct 2026): `NODE_VERSION` in `build.lua` (single source
  of truth — `sign-macos.sh` reads it from there), `scripts/lens/.nvmrc`, and the
  `node-version` fields in ci.yml. Verify with `just check` + `just lens-test`.

### Prevention (so this never recurs)

- **Brain rule (cross-project):** new `~/Documents/Brain/feedback_pin_supported_runtimes.md` —
  *before pinning any runtime/toolchain version, check its lifecycle (endoflife.date);
  pin the newest Active LTS; and any pin Dependabot can't see must get an automated EOL
  guard in CI the same day it's introduced.* Why: a stale pin fails silently — nothing
  breaks until users are already running EOL software. Indexed in Brain `MEMORY.md`,
  committed + pushed (Brain is a git repo).
- **Repo guard (automated):** new CI job `runtime-eol-guard` — runs weekly on a schedule
  and on any PR touching `build.lua` / `.nvmrc`. It queries the endoflife.date API for
  Node, and **fails** if the pinned major is EOL (or within 60 days of it) or if `.nvmrc`
  and `build.lua` disagree; it **notices** when a newer patch of the pinned LTS line
  exists. The weekly run means the alarm fires even when nobody touches the repo.
- Dependabot already watches the other two update surfaces (npm, actions); with the guard
  covering the custom pin, every version in the repo is now watched by machinery.

## Issue 5 — CI stops testing signing; releases are cut locally ✅ direction decided

Signing secrets will **not** be added to GitHub. So CI's job is validation, not release:

- **Remove the `notarize-macos` and `release` jobs** from ci.yml. Tag pushes still run
  build + lens-helper + the version-drift guard (plus the new eol-guard); CI can no longer
  go red for signing reasons, and no unsigned zip can ever be published by CI.
- **Releases become one local command** (per the one-command Brain principle):
  `./release.sh` gains a final publish step — after sign + notarize + package it verifies
  `git tag v<VERSION>` exists and matches, generates notes via git-cliff, and runs
  `gh release create` with all three zips + `checksums.txt`. Clean checkout → published
  GitHub release, one command, keys never leave the Mac. (A `--no-publish` flag preserves
  today's build-only behavior.)
- Docs follow: SIGNING.md drops its "CI secrets" section (locally-run signing only),
  INSTALLERS-PLAN.md gets a pointer to this doc, and the stale
  "add the 7 secrets to make CI self-sufficient" guidance is retired.

## Implementation order

1. `VERSION` → `0.2.0-dev`; CHANGELOG section opened. Everything below lands under it.
2. Merge Dependabot PR #1 + PR #2. *(4)*
3. Node 24 LTS bump (`build.lua`, `.nvmrc`, ci.yml); `just check` + `just lens-test`. *(4)*
4. Packaging rework in `build/build.lua` + `scripts/sign-macos.sh`: three zips with prune +
   rename, notarize `-mac` + `-all`, checksums for all three. *(1, 3)*
5. ci.yml: remove `notarize-macos` + `release`; smoke-check all three zips (the `-win` zip
   contains no darwin Node, `-mac` no `node.exe`, `-all` both); add `runtime-eol-guard`. *(4, 5)*
6. `release.sh`: local publish step (`gh release create`, `--no-publish` flag). *(5)*
7. Docs: README.md install section (3 assets, per-OS steps, Windows layout note),
   SIGNING.md, INSTALLERS-PLAN.md. *(2, 3)*
8. Brain: `feedback_pin_supported_runtimes.md` + MEMORY.md index line, commit + push. *(4)*
9. Verify end-to-end: local `./release.sh --no-publish` dry-run → `unzip -l` layout checks +
   real sizes; browser-download Gatekeeper test on the Mac; Extract-All + Plug-in Manager
   install test on the Windows VM; test tag → CI fully green (validation-only).
10. Ship **v0.2.0** (tag + `./release.sh`).
