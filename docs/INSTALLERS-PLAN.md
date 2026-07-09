# Plan: Distribution & signing for Species Tagger

*Lightroom Classic plugin. Planning doc — updated 2026-07-09. Pivoted to **sign + notarize
the bundled binary**; native installers and Adobe Exchange are now optional later layers.*

## Goal

Make the released plugin **just work when a real user downloads it**, on both Mac
architectures, with **no OS security warnings** — while keeping the standard, familiar
Lightroom install flow (download the zip, then File ▸ Plug-in Manager ▸ Add). The one thing
that breaks that flow today is the bundled **Node binary**: downloaded unsigned, macOS
Gatekeeper quarantines and blocks it on first run. Fix that at the source by **signing +
notarizing the binary** inside the zip we already build. Native installers and an Adobe
Exchange listing become **optional layers**, not the core of the work.

## Why this scope (and why not native installers)

For Lightroom Classic, the universal, expected way to install a plugin is "unzip and add it
in Plug-in Manager." Native installers are the exception — mostly commercial consumer suites,
not typical plugins. Species Tagger is unusual only in that it ships a native Node executable,
and that executable is the *sole* reason a plain download misbehaves on macOS.

And it's a **provenance** problem, not a packaging problem. The same binary that runs fine
when you build it locally (built with `curl`/`tar`, which never attach the
`com.apple.quarantine` flag) is blocked when a user downloads the zip through a browser (which
attaches it, and Finder propagates it onto the extracted binary on unzip). **Notarization
fixes it regardless of how the file arrived** — exactly what a downloaded artifact needs, and
what "strip the quarantine flag in an installer" cannot guarantee (that only helps if you
control the unzip). So the smallest change that actually solves it is to sign + notarize the
binary in the zip and keep everything else the same.

Adobe Exchange doesn't remove this work either: Adobe explicitly leaves signing/notarization
to the developer, doesn't do per-architecture selection, and adds a review step this plugin's
Google Lens/Chrome design could fail. It's a discovery / one-click-install *layer* on top of
the same signed bundle — useful later, not a substitute for the fix.

## Decisions locked in

| Decision | Choice |
|---|---|
| **Primary approach** | **Sign + notarize the bundled Node binary**, shipped in the existing `SpeciesTagger.lrplugin-<ver>.zip`. Keep the standard Plug-in Manager ▸ Add install. |
| **macOS archs** | One **universal** `node` (Intel + Apple Silicon) via `lipo` — no plugin change, no per-arch artifacts. |
| **Windows** | Nothing to sign for the zip — the official `node.exe` is already Authenticode-signed and Windows doesn't quarantine-kill it. |
| **Signing cert** | Apple Developer Program ($99/yr) → **Developer ID Application** cert + notarization. (A Windows cert / Azure Trusted Signing is only needed *if* we later add a Windows **installer** .exe.) |
| **Native installers / Adobe Exchange** | **Optional, later.** Documented below, out of core scope. |

## What actually ships

No new artifact types. The same `SpeciesTagger.lrplugin-<ver>.zip` + `checksums.txt` you
release today — but the `node` inside is now a signed, notarized **universal** binary. End
users download, unzip, and Add exactly as the README describes. On first run the tool reaches
the network anyway (Google Lens + GBIF), so the one nuance of notarizing a bare binary — that
Gatekeeper does an online check rather than reading a stapled ticket — costs nothing here.

## macOS: the signing pipeline

1. **Universal Node.** In `scripts/sign-macos.sh` (release-time, so the plugin's tested Lua
   build stays untouched), fetch both official Node builds (`darwin-arm64`, `darwin-x64`) and
   `lipo -create` them into a single universal `node`. Placed at the existing
   `node/darwin-arm64/node` path, it runs natively on both archs, so `resolveNode` in
   `src/shared/Http.lua` needs **no change** and there's nothing to select at install time.
2. **Sign** the universal `node` with the **Developer ID Application** cert, hardened runtime,
   and a secure timestamp:
   `codesign --force --options runtime --timestamp --sign "Developer ID Application: <you>" node`.
   (`puppeteer-core` is pure JS — no other Mach-O in the bundle to sign.)
3. **Notarize.** Zip the signed `node` (or the whole `.lrplugin`) and submit with
   `xcrun notarytool submit --wait` (App Store Connect API key). A bare binary/folder can't be
   **stapled**, so we rely on Gatekeeper's online check on first run — fine, since the plugin
   is online by nature. *(If we ever want offline first-run, that's the trigger to move to a
   `.pkg`/`.dmg`, which can be stapled — an installer-tier concern, not needed now.)*
4. **Verify** on a clean machine via the real download path (see Testing).

## Windows

Nothing required for the zip. The bundled `node.exe` from nodejs.org is already
Authenticode-signed by the OpenJS Foundation, and Windows has no Gatekeeper-style
quarantine-kill for a signed executable that Lightroom launches. The `win-x64` build also runs
on Windows-on-ARM via x64 emulation, so one build covers both. (SmartScreen only becomes a
factor if we later add our own installer `.exe`.)

## README + discovery

- **Install instructions near the top of the README** (doing this now): move the
  "Install (from a release)" steps to the first section after the intro, so a reader sees
  download → unzip → Plug-in Manager ▸ Add immediately. With signed releases the steps stay
  clean — no Gatekeeper caveat needed.
- **Discovery (free):** request a listing in the
  [Lightroom Queen plugin directory](https://www.lightroomqueen.com/links/plugins/) — where
  Lightroom Classic users actually look.

## CI / release integration

Today CI is Linux-only and, on a `v*` tag, publishes the zip + checksums. Add one macOS step:

- **Compose on Linux** (existing `build` job): fetch both darwin Node builds so they're
  available to `lipo`. Everything else stays as-is.
- **macOS job** (`macos-14` runner, `v*` tags only, gated on the green `build` +
  `lens-helper` jobs): `lipo` the universal `node`, `codesign` it (Developer ID), run
  `notarytool submit --wait`, refresh the zip with the signed binary, hand it to the release
  job.
- **Secrets:** Developer ID Application `.p12` (+ password) imported into a temp keychain, and
  an App Store Connect API key (id / issuer / `.p8`) for `notarytool`.
- **Local-first:** the same steps run as a short `scripts/sign-macos.sh` on your Mac, so you
  can cut a signed release by hand before the CI wiring lands.

## Testing plan

The test that matters — and the one you've never actually run — is the **real end-user
download path**, because your local build never attaches the quarantine flag:

- **Reproduce the bug first** (to prove the fix): on your Mac, stamp the flag on a *built*
  binary and confirm a tag run is blocked —
  `xattr -w com.apple.quarantine "0081;00000000;Safari;" output/dist/SpeciesTagger.lrplugin/node/darwin-arm64/node` —
  or download the current release zip through a browser and unzip it in Finder.
- **Confirm the fix:** with the signed + notarized universal binary, download the *new* release
  through a browser, unzip in Finder, and run a tag on a clean **Apple-Silicon** Mac **and** an
  **Intel** Mac — no Gatekeeper block, both archs run. Check `codesign --verify --strict`,
  `spctl --assess --type execute`, and `xcrun notarytool history`.
- **Windows:** install from the zip on the Parallels VM (per the live-testing notes) and
  confirm the tag flow.

## Optional later layers (out of core scope)

- **Native installers** — auto-load into Lightroom's `Modules` folder, double-click, no
  Plug-in Manager step: a consumer-grade polish. Needs a signed macOS `.pkg`
  (`pkgbuild`/`productbuild` + notarize; mind the per-user home domain) and a signed Windows
  `.exe` (Inno Setup + Azure Trusted Signing, ~$10/mo). Build only if you want the double-click
  experience.
- **Adobe Exchange (ZXP)** — repackage the signed bundle as a signed ZXP for one-click install
  via the Creative Cloud desktop app plus catalog discovery. Reuses the same signed binary;
  requires Adobe review (confirm the LrC pathway with `ccintrev@adobe.com` first, and expect
  scrutiny of the Lens/Chrome behavior).

## Phased rollout

**Status (2026-07-09):** Phases 1–4 are implemented and committed — the signing script, the
CI job, the README change, and the maintainer doc. They're gated only on the Developer ID from
Phase 0; once the cert + GitHub secrets are in place, signing and notarization run for real.

- [ ] **Phase 0 — Prereq (purchase, in progress).** Apple Developer Program ($99/yr); create a
      **Developer ID Application** cert + an App Store Connect API key for notarization, then
      add the GitHub secrets listed in [SIGNING.md](SIGNING.md).
- [x] **Phase 1 — Universal Node.** `lipo` step implemented in `scripts/sign-macos.sh`
      (release-time, so the plugin's tested Lua build is untouched). Validate on both archs now
      with `bash scripts/sign-macos.sh --allow-unsigned` on your Mac.
- [x] **Phase 2 — Sign + notarize.** `scripts/sign-macos.sh` does codesign (Developer ID +
      hardened runtime) + `notarytool`; `--allow-unsigned` runs everything except signing, so
      it's usable before the cert. Runs the moment `MACOS_SIGN_IDENTITY` is set.
- [x] **Phase 3 — README.** Install instructions moved to the top of the README. *(Still open:
      request the Lightroom Queen directory listing.)*
- [x] **Phase 4 — CI.** `notarize-macos` job added (tag-gated, `macos-14`); the `release` job
      now publishes the signed zip. Inert until the Phase 0 secrets exist.
- [ ] **(Optional) Phase 5 — Installer / Exchange layers**, if a one-click experience is wanted.

**Effort:** much smaller than a native-installer build — the core is the `lipo` step, a short
sign/notarize script, and one CI job (all done). Phase 0 is calendar time (enrollment) that
runs in parallel.

## Sources

- macOS quarantine mechanics — [Eclectic Light Co.](https://eclecticlight.co/2020/10/29/quarantine-and-the-quarantine-flag/), [Homebrew-cask: curl downloads aren't quarantined](https://github.com/Homebrew/homebrew-cask/issues/22388)
- Notarizing a standalone binary (online check, no stapling) — [Rob Allen](https://akrabat.com/notarising-a-macos-standalone-binary/), [Apple: notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- Apple Developer Program — [developer.apple.com/programs](https://developer.apple.com/programs/)
- LrC plugin install norm — [Adobe: use & manage plugins](https://helpx.adobe.com/lightroom-classic/how-to/lightroom-use-manage-plugins.html), [Jeffrey Friedl](https://regex.info/blog/lightroom-goodies/plugin-installation)
- Adobe Exchange leaves signing to developers — [Adobe: LrC plugin support on Exchange](https://blog.developer.adobe.com/lightroom-classic-plugin-support-for-the-adobe-exchange-for-creative-cloud-14e4a0f690df)
