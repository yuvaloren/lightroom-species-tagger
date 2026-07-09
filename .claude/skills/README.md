# Project skills

These are [Claude Code](https://claude.com/claude-code) **skills** — short, versioned
playbooks that encode *this project's* standards as repeatable procedures. Each is a
`SKILL.md` with a `description` that tells the assistant when to reach for it. They exist
so the right way to do a recurring task (cut a release, review a PR, edit the brittle Lens
helper, change the Lightroom glue) is applied consistently — by an assistant *or* by a
human reading them as checklists — without that knowledge living only in one maintainer's
head.

They are plain Markdown: useful whether or not you use Claude Code. If you don't, read
the relevant one before the matching task and follow it by hand.

| Skill | Use it when… |
|---|---|
| [cut-release](cut-release/SKILL.md) | Shipping a tagged version without tripping the CI version-drift guard. |
| [review-incoming-pr](review-incoming-pr/SKILL.md) | Reviewing an inbound PR against the real gate + design rules. |
| [edit-lens-helper](edit-lens-helper/SKILL.md) | Touching the Node/Puppeteer Google Lens helper (`scripts/lens`). |
| [update-lightroom-glue](update-lightroom-glue/SKILL.md) | Changing the Lightroom plugin glue (menus, settings, catalog writes). |

They complement — never replace — the [README](../../README.md) and
[ARCHITECTURE.md](../../docs/ARCHITECTURE.md): those explain the project; these are the
step-by-step for specific recurring tasks. When a procedure changes, update the skill in
the same PR.
