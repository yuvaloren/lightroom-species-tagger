# Signing & notarizing macOS releases

The plugin bundles a per-OS Node runtime. On macOS that binary is the one thing that
breaks a plain download: an **unsigned** binary that arrives **quarantined** (a browser
download, then a Finder unzip) is blocked by Gatekeeper on first run. Local builds never
hit this because `curl`/`tar` don't attach the `com.apple.quarantine` flag — only a
browser download does — so the bug only shows up for real end users. See
[INSTALLERS-PLAN.md](INSTALLERS-PLAN.md) for the full reasoning.

[`scripts/sign-macos.sh`](../scripts/sign-macos.sh) fixes it at the source: it makes the
bundled Node a **universal** binary (Intel + Apple Silicon in one), **codesigns** it with a
Developer ID Application identity + hardened runtime, **notarizes** the packaged zip, and
repackages `output/dist/SpeciesTagger.lrplugin-<version>.zip` + `checksums.txt`. Nothing in
the plugin's Lua changes — `resolveNode` still loads `node/darwin-arm64/node`, which is now
universal.

## One-time prerequisites (Apple Developer)

1. **Apple Developer Program** membership ($99/yr).
2. A **Developer ID Application** certificate. Create it in Xcode (Settings ▸ Accounts ▸
   Manage Certificates ▸ +) or on the Apple Developer portal; it installs into your login
   keychain. Its identity name looks like `Developer ID Application: Your Name (TEAMID)` —
   list yours with `security find-identity -v -p codesigning`.
3. An **App Store Connect API key** for notarization (App Store Connect ▸ Users and Access ▸
   Integrations ▸ Keys). Note the **Key ID** and **Issuer ID**, and download the `.p8` once.

## Running it locally

**One command** takes a clean checkout to a signed, notarized, distributable zip:

```bash
./release.sh                   # full signed + notarized release -> output/dist/
./release.sh --allow-unsigned  # before your Developer ID exists (universal Node only)
```

`release.sh` bootstraps the pinned Lua toolchain and the Lens helper deps if they're missing,
composes the bundle (darwin universal + win-x64), then makes the Node runtime universal,
code-signs it, notarizes, and packages — the whole pipeline in one process.

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

`--allow-unsigned` is the "do everything you can before the cert lands" mode: it fetches the
x64 Node, lipos the universal binary, and repackages — so you can confirm the universal build
runs on both architectures now. The zip it produces is **not** for distribution.

Under the hood `release.sh` just chains the repo's existing pieces (`dev-setup.sh` → `npm ci`
→ `build.sh` → `scripts/sign-macos.sh`); run those individually only for inner-loop debugging.

## Running it in CI

The `notarize-macos` job in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on
`v*` tags: it composes the bundle on a `macos-14` runner, runs `sign-macos.sh`, and uploads
the signed zip, which the `release` job then publishes. It stays **inert until these GitHub
repository secrets exist**:

| Secret | What it is |
|---|---|
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `MACOS_CERT_P12_BASE64` | Your Developer ID cert + private key exported as `.p12`, base64-encoded (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERT_PASSWORD` | The password you set when exporting the `.p12` |
| `MACOS_KEYCHAIN_PASSWORD` | Any random string — password for the throwaway CI keychain |
| `NOTARY_KEY_ID` | App Store Connect API **Key ID** |
| `NOTARY_ISSUER_ID` | App Store Connect API **Issuer ID** |
| `NOTARY_KEY_P8_BASE64` | The API key `.p8`, base64-encoded |

Until they're added, a tag build simply fails at the signing step (it never ships an unsigned
zip) — regular push/PR CI is unaffected because the job is tag-gated.

## Verifying a signed build

```bash
codesign --verify --strict --verbose=2 output/dist/SpeciesTagger.lrplugin/node/darwin-arm64/node
spctl --assess --type execute --verbose=4 output/dist/SpeciesTagger.lrplugin/node/darwin-arm64/node
lipo -info output/dist/SpeciesTagger.lrplugin/node/darwin-arm64/node   # -> arm64 x86_64
xcrun notarytool history --key ... --key-id ... --issuer ...
```

## Reproducing the bug the fix prevents

To see the failure a downloader would hit (and confirm the signed build clears it), stamp the
quarantine flag on a built binary and run a tag:

```bash
xattr -w com.apple.quarantine "0081;00000000;Safari;" \
  output/dist/SpeciesTagger.lrplugin/node/darwin-arm64/node
```

Or download the release zip through a browser and unzip it in Finder (double-click), which
propagates the flag onto the extracted binary. An unsigned binary is blocked; a signed +
notarized one is cleared by Gatekeeper's online check on first run.
