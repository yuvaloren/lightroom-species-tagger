# Troubleshooting

### “Could not load toolkit script” after updating the plugin
Lightroom's **Reload Plug-in** doesn't always register a newly-*added* script file. After
re-installing an update that added a module, **remove the plug-in in Plug-in Manager and
Add it again**, or simply **restart Lightroom Classic**. A plain Reload is enough only when
existing files changed.

### The Lens window doesn't open / “helper produced no output”
The Lens step opens your installed Chrome via a bundled Node helper. Check:
- **Node + Chrome installed.** The released bundle ships the helper's deps, so there's
  nothing to `npm install`. The helper finds Chrome and Node automatically on
  macOS / Windows / Linux.
- Run from a normal home (residential) connection — Google challenges datacenter/VPN/shared
  IPs. If an "are you human" check appears, solve it yourself in the window, then highlight
  and Tag as usual.

### Chrome says it “didn't shut down correctly”
The plugin closes its Lens window cleanly at the end of a run, so you shouldn't see this. If
you do (e.g. you quit Lightroom mid-run and it was force-closed), just dismiss the restore
prompt — nothing is lost, and the next run opens a fresh window.

### I can't find the species in the results
The plugin tags only what **you** highlight, so this is about the Lens results, not the
plugin:
- Refine in **Google's own search box** (add words like `juvenile`, or crop the image).
- Pick a different visual match, or scroll to the AI-overview line, then highlight the
  Latin name and press **Tag**.
- Not sure? Press **Skip** to leave the photo untagged and move on.

### Wrong keyword applied
Nothing is read until you press Tag, so: highlight the correct name and press **Tag** again.
To remove an incorrect keyword, delete it from Lightroom's **Keyword List**.

### Two animals in one photo
Highlight the first, press Tag, then highlight the second and press Tag again before moving
to the next photo — both keywords accumulate on the photo.

### HEIC / raw files
The plugin uses Lightroom's own preview rendering, so any format Lightroom can preview (raw,
HEIC, etc.) works — no separate conversion needed.

### Rate limits / challenges
Lens has no published quota, but Google may challenge a busy or non-residential network.
Run from a residential connection and keep batches modest; if a check appears, solve it in
the window.

### Reset
Removing keywords the plugin added is a normal Lightroom keyword operation. To reset the
Lens session, delete the local Chrome profile/cookie jar (see [Privacy](PRIVACY.md)).
