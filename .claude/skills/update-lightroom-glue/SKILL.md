---
name: update-lightroom-glue
description: Change the Lightroom plugin glue (menus, dialogs, settings, catalog writes) without breaking catalog or async safety — for contributors new to Lua or the Lightroom SDK. Use when editing src/SpeciesTagger.lrplugin/ (Info, TagSpecies, the menu item, or the settings panel).
---

# Update the Lightroom glue

The files in `src/SpeciesTagger.lrplugin/` are the *thin* layer that talks to Lightroom.
Everything interesting lives in the pure `src/shared/` core; the glue only renders,
gathers input, and writes the catalog. If you're new to Lua or the LrC SDK, this is the
guardrail so a change here doesn't wedge Lightroom or duplicate keywords.

Full mental model: [ARCHITECTURE.md](../../../ARCHITECTURE.md). SDK reference:
<https://developer.adobe.com/lightroom-classic/>.

## The mental model

- **`Info.lua`** registers the menu commands and the settings panel. The `VERSION`
  table is stamped by the build — don't hand-edit the numbers.
- **Each menu item** `SpeciesTaggerMenuItem.lua` wraps its
  work in `LrTasks.startAsyncTask` → `LrFunctionContext.callWithContext` →
  `LrTasks.pcall`, so a stray error surfaces as a message instead of hanging Lightroom.
  Keep that wrapper.
- **`TagSpecies.run` is the only code that writes the catalog.** Writes go through a
  per-photo `catalog:withWriteAccessDo('...', fn, { timeout = 30 })`, and keywords are
  created with `createKeyword(..., returnExisting = true)` so re-runs never duplicate.
- **`SpeciesTaggerInfoProvider.lua`** is the settings panel.

## Rules that bite if you miss them

- **Settings controls must bind to prefs.** Every control needs
  `bind_to_object = prefs` (there's a `bind` helper that sets it). Without it the
  control opens empty, shows the indeterminate "–", and never persists.
- **A new setting is three edits, in lock-step:** add the key + default to
  `Config.DEFAULTS` (with a comment), add the control in `SpeciesTaggerInfoProvider`,
  and thread `cfg.<key>` to wherever it's used. Add a `spec/config_spec.lua` assertion
  for the default.
- **Keep logic OUT of the glue.** A decision/algorithm belongs in a pure `src/shared/`
  module with a spec — not in a `.lrplugin` file. If you're writing a loop that scores
  or parses here, move it behind the seam.
- **Fail soft.** A Skip, timeout, or unresolved name leaves the photo untouched — it
  must never crash the batch or mis-tag.

## Verify

The pure core is fully covered by `just check` with no Lightroom. The glue itself needs
a real, **licensed Lightroom Classic** to exercise (there's no headless LrC):

1. `./install.sh` builds + installs a full plugin copy into `~/Documents/Lightroom Plugins/`.
2. First time: **Add** it in Plug-in Manager. After a rebuild: **Reload Plug-in**.
3. Run it (`Library ▸ Plug-in Extras ▸ Identify and Tag Species`) and check the result
   in the Keyword List. Runtime logs are in Lightroom's `Documents/` logs folder.

Still run `just check` for anything you can — most bugs are in the pure layer that it
covers offline.
