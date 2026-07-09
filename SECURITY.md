# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for
anything exploitable.

- Preferred: open a [private security advisory][advisory] on GitHub
  (**Security ▸ Report a vulnerability**).
- Alternatively, contact the maintainer at the email on their GitHub profile.

Please include the version (`VERSION` / the plugin's version label), your OS,
and steps to reproduce. You can expect an acknowledgement within a few days.
This is a small, single-maintainer project, so please allow reasonable time for
a fix before any public disclosure.

[advisory]: https://github.com/yuvaloren/lightroom-species-tagger/security/advisories/new

## Supported versions

Fixes land on `main` and go out in the next tagged release. Only the latest
release is supported — there are no long-lived maintenance branches.

## What this plugin does with your data and your machine

Being explicit about the trust boundaries, since the interesting surface is not
obvious from the outside (see also [docs/PRIVACY.md](docs/PRIVACY.md)):

- **It uploads a downsized, freshly-rendered JPEG to Google Lens.** The re-render
  strips the original EXIF/GPS. Only the pixels go to Google; nothing else.
- **It opens an anonymous Lens session in your installed Google Chrome** via
  `puppeteer-core` (it does *not* download a browser), in a dedicated profile under
  `~/.cache/speciestagger-lens`. That directory holds session cookies — treat it like
  a browser profile and delete it to reset. The plugin does **not** read or scrape the
  page: you highlight the species yourself and it captures only that selection
  (`window.getSelection()`).
- **It shells out to Node.js.** The Lua side builds the command from fixed arguments
  and the image path, shell-quoted per platform
  ([`src/shared/Http.lua`](src/shared/Http.lua)). No user-typed text is passed to the
  helper — you add keywords in Google's own search box, in the visible browser.
- **Taxonomy lookups send only names** (never images or location) to the public
  GBIF API over HTTPS.
- **No API keys or account credentials** are used or stored. There is no server
  component and no telemetry.
- **Logs are redacted.** Anything that looks like a cookie or API key is masked
  before it reaches the Lightroom plugin log ([`src/shared/Log.lua`](src/shared/Log.lua)).

## Dependency & supply-chain notes

- The only third-party runtime code that ships inside the `.lrplugin` is
  `puppeteer-core` (drives Chrome) and `dkjson` (JSON). Both are pinned; the
  npm lockfile is committed so release builds are reproducible (`npm ci`).
- Dependency updates are proposed automatically via Dependabot
  ([`.github/dependabot.yml`](.github/dependabot.yml)) and gated by CI.

## Scope

This plugin opens a consumer Google surface (Lens) in your own visible browser and reads
only the text you highlight — it does not scrape or extract Google's results. Google can
still change or challenge the page, which is a **maintenance and reliability** risk, not a
security vulnerability in this project. Reports about the *plugin's* handling of your data,
files, or machine are in scope; "Google changed their page" is a bug, not a security
report.
