---
name: review-incoming-pr
description: Review a contributor pull request against THIS repo's actual gate and design rules (not generic advice). Use when triaging or reviewing an inbound PR, or when asked to review changes for merge-readiness.
---

# Review an incoming PR

This project's quality bar is concrete and enforced. Review against *these* rules, in this
order, and be specific about what fails. The goal is to keep the pure/tested core pure and
the compliance line intact while staying welcoming to less-experienced contributors — so
lead with what to fix, not just what's wrong.

## 1. The gate is the source of truth

```bash
just check     # luacheck (0 warnings) + busted + build. Exactly what CI runs.
```

If it isn't green, that's the first ask. No `just`?
`luacheck src spec scripts && busted && lua build/build.lua`.

## 2. Design rules (where the real review value is)

- **Logic belongs in the pure core.** New decision logic should live in `src/shared/` with
  I/O injected via `deps`, **not** in the Lightroom glue (`src/*.lrplugin/`). A glue-side
  algorithm is a red flag — ask for it to move behind the seam with a spec. See
  [ARCHITECTURE.md](../../../ARCHITECTURE.md).
- **New/changed logic has a spec.** Pure functions get white-box tests via the module's
  `_test` table. No spec ⇒ ask for one.
- **The plugin must never scrape Google.** Any change to the Lens helper must read only the
  user's selection (`window.getSelection`), never the results DOM — this is the compliance
  guarantee the docs make. Apply [edit-lens-helper](../edit-lens-helper/SKILL.md).
- **Lightroom-glue changes** get the [update-lightroom-glue](../update-lightroom-glue/SKILL.md)
  checklist (async wrapper intact, `TagSpecies` the only catalog writer, settings bound to
  prefs).

## 3. Privacy

- No real personal photos or EXIF in any added fixture. New GBIF fixtures are impersonal
  API responses; keep any other test data open-licensed or synthetic.

## 4. Housekeeping

- **Conventional Commits** title (`feat:`/`fix:`/`docs:`…) — it feeds the CHANGELOG
  generator, so a non-conforming title silently drops from release notes.
- User-facing behavior change ⇒ `CHANGELOG.md` (and README/docs) updated.
- Comments explain **why**, not what. Tabs for Lua indentation.

## Verdict

Summarize as: **gate status**, then **must-fix** (design-rule or correctness), then
**nice-to-have**. Be concrete and kind — point at the file/line and the fix. First-time
contributor? Say what's already good, too.
