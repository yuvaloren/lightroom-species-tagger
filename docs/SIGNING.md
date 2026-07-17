# Signing & notarizing macOS releases

The plugin bundles one per-OS native binary — the Go lens helper. On macOS that
binary is the one thing that breaks a plain download: an **unsigned** binary that
arrives **quarantined** (a browser download, then a Finder unzip) is blocked by
Gatekeeper on first run. Local builds never hit this because `curl`/`tar` don't
attach the `com.apple.quarantine` flag — only a browser download does — so the bug
only shows up for real end users. See [INSTALLERS-PLAN.md](INSTALLERS-PLAN.md) for
the full reasoning.

[`scripts/sign-macos.sh`](../scripts/sign-macos.sh) fixes it at the source: it
verifies the bundled helper is **universal** (Intel + Apple Silicon in one — built
by `make -C helper universal`), **codesigns** every Mach-O with a Developer ID
Application identity + hardened runtime (no entitlements needed — Go doesn't JIT,
unlike the old Node runtime), packages the three per-platform zips via
[`scripts/package-zips.sh`](../scripts/package-zips.sh)
(`SpeciesTagger-<version>-mac/-win/-all.zip` + `checksums.txt`), and **notarizes**
the mac-containing ones (`-mac`, `-all`; the `-win` zip ships no Mach-O). Nothing
in the plugin's Lua changes — `resolveHelper` loads
`helper/darwin-universal/lens-helper`.

## One-time prerequisites (Apple Developer)

1. **Apple Developer Program** membership ($99/yr).
2. A **Developer ID Application** certificate. Create it in Xcode (Settings ▸ Accounts ▸
   Manage Certificates ▸ +) or on the Apple Developer portal; it installs into your login
   keychain. Its identity name looks like `Developer ID Application: Your Name (TEAMID)` —
   list yours with `security find-identity -v -p codesigning`.
3. An **App Store Connect API key** for notarization (App Store Connect ▸ Users and Access ▸
   Integrations ▸ Keys). Note the **Key ID** and **Issuer ID**, and download the `.p8` once.

## Running it locally

**One command** takes a clean checkout to a signed, notarized, **published** release:

```bash
./release.sh                   # sign + notarize + package + publish the GitHub Release
./release.sh --no-publish      # everything except the GitHub Release (dry run)
./release.sh --allow-unsigned  # before your Developer ID exists (universal Node only)
```

`release.sh` bootstraps the pinned Lua toolchain and the Lens helper deps if they're missing,
composes the bundle (darwin universal + win-x64), makes the Node runtime universal,
code-signs it, packages the three zips, notarizes, and publishes them with
`gh release create` — the whole pipeline in one process. Publishing requires the release
tag at HEAD (see the `cut-release` skill).

Set signing up once: store a notary profile, and put your identity + profile in a gitignored
`scripts/signing.env` that `release.sh` sources (so nothing goes on the command line):

```bash
xcrun notarytool store-credentials notary \
  --key /path/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>

cat > scripts/signing.env <<'ENV'   # gitignored
export MACOS_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE=notary
ENV
```

`--allow-unsigned` is the "do everything you can before the cert lands" mode: it
verifies the universal helper and repackages — so you can confirm the universal
build runs on both architectures now. The zip it produces is **not** for
distribution.

Under the hood `release.sh` just chains the repo's existing pieces (`dev-setup.sh`
→ `make -C helper universal` → `build.sh` → `scripts/sign-macos.sh`); run those
individually only for inner-loop debugging.

## Why signing does NOT run in CI

**Decision (2026-07-09): the signing identity and notary credentials never leave this Mac.**
Putting the Developer ID private key (as a `.p12`) and the notary API key into GitHub
secrets would make GitHub a custodian of code-signing identity; a leak there would let
anyone sign software as "Yuval Oren". So CI is **validation-only** — lint, tests, an
unsigned bundle build with per-zip content checks, and the weekly Go-EOL guard — and the
signed release is produced and published locally by `./release.sh`. The env-var hooks that
`sign-macos.sh` reads (`MACOS_CERT_P12_BASE64`, `NOTARY_KEY_P8_BASE64`, …) still exist for
any future runner **you** control, but no GitHub-hosted workflow uses them.

## Verifying a signed build

```bash
codesign --verify --strict --verbose=2 output/dist/SpeciesTagger.lrplugin/helper/darwin-universal/lens-helper
spctl --assess --type execute --verbose=4 output/dist/SpeciesTagger.lrplugin/helper/darwin-universal/lens-helper
lipo -info output/dist/SpeciesTagger.lrplugin/helper/darwin-universal/lens-helper   # -> x86_64 arm64
xcrun notarytool history --key ... --key-id ... --issuer ...
```

## Reproducing the bug the fix prevents

To see the failure a downloader would hit (and confirm the signed build clears it), stamp the
quarantine flag on a built binary and run a tag:

```bash
xattr -w com.apple.quarantine "0081;00000000;Safari;" \
  output/dist/SpeciesTagger.lrplugin/helper/darwin-universal/lens-helper
```

Or download the release zip through a browser and unzip it in Finder (double-click), which
propagates the flag onto the extracted binary. An unsigned binary is blocked; a signed +
notarized one is cleared by Gatekeeper's online check on first run.

## Windows: Azure Trusted Signing (the installer .exe)

The Windows story is split in two:

- **The zips' `lens-helper.exe` is currently unsigned** — unlike the old bundled
  `node.exe` (Authenticode-signed by the OpenJS Foundation), the Go helper is our
  own binary. Until Azure Trusted Signing covers it too, expect the standard
  unknown-publisher posture; `scripts/sign-win.sh` is the hook for signing BOTH
  the installer and the helper exe once ATS is configured.
- **`SpeciesTagger-win-setup.exe`** (the NSIS installer) is ours, so SmartScreen judges
  it by *our* signature. It is signed with **Azure Trusted Signing** by
  `scripts/sign-win.sh`, which release.sh calls automatically — from the Mac, no
  Windows box in the loop.

How it works: `az account get-access-token` mints a **short-lived token** for the
`codesigning.azure.net` resource; [jsign](https://ebourg.github.io/jsign/) (cross-platform
Authenticode) sends the exe's digest to the Trusted Signing service, which signs with the
certificate profile and returns the signature; jsign embeds it plus an RFC 3161 timestamp
(`timestamp.acs.microsoft.com`). Trusted Signing certs rotate every ~3 days, so the
timestamp is what keeps installers valid forever.

One-time prerequisites:

1. `brew install azure-cli jsign` (osslsigncode optional, for a local structural verify).
2. An Azure **Trusted Signing account** + **certificate profile** (public-trust; needs
   the one-time identity validation), and the signer identity holding the
   **"Trusted Signing Certificate Profile Signer"** role.
3. `az login` on the release Mac.
4. In the gitignored `scripts/signing.env` (names, not secrets):

   ```sh
   ATS_ENDPOINT=<region>.codesigning.azure.net
   ATS_ACCOUNT=<trusted-signing-account-name>
   ATS_PROFILE=<certificate-profile-name>
   ```

No secrets are stored anywhere — the same "no signing secrets on GitHub, ever" rule as
macOS: CI never signs; `./release.sh` on this Mac does. If the ATS_* variables are unset,
sign-win.sh warns and ships the exe unsigned (one-time SmartScreen "More info ▸ Run
anyway"). Authoritative verification is `Get-AuthenticodeSignature` on a Windows box;
SmartScreen reputation with a Trusted Signing certificate is typically immediate-to-fast.
