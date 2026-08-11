---
name: spox
description: Use this skill when the user wants to check, list, or update project specs tracked in a .spox/ directory. Trigger whenever the user mentions "spox", asks about spec status, wants to see what's in progress, references a .spox directory, asks about open criteria or unchecked tasks in specs, or wants to create or update a spec file. When in doubt, use this skill — it's the right tool any time specs or project status tracking come up.
allowed-tools: Bash(spox list) Bash(spox list -c) Bash(spox list --criteria) Bash(spox list -t) Bash(spox list --tagline) Bash(spox view *) Bash(spox view -c *) Bash(spox view --criteria *) Bash(spox check *) Bash(spox check * all) Bash(spox version)
hooks:
  PreToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: "${CLAUDE_SKILL_DIR}/check-chain.sh"
          timeout: 5
---

## What spox does

`spox` is an installed CLI tool that lists and updates spec statuses from a `.spox/` directory, walking up the tree from CWD (git-style) to find it. Run it via Bash.

## Commands

```
spox list                      # list all specs with their status
spox list -c                   # also show labelled open criteria under each spec
spox list --criteria           # same as -c
spox list -t                   # show each spec's one-line tagline (if set)
spox list --tagline            # same as -t
spox view <spec>               # show the full raw spec file
spox view -c <spec>            # show a single spec's open criteria in dashboard format
spox init                      # create .spox/ in the current directory (new projects)
spox check <spec> <label>      # check off the criterion with the given label (stable, preferred)
spox check <spec> <n>          # check off the nth open criterion (positional — avoid in scripts)
spox check <spec> all          # check off all remaining open criteria at once
spox status <spec> <value>     # set the status field of a spec
spox skill install             # copy this skill into the project's .claude/skills/
spox version                   # print the installed version
spox help                      # show usage
```

## Reading the output

Each line is `<spec-name>  <status>`. With `list -c`, open criteria appear labelled below:

```
auth      in-progress
  ┣━ [a3f2] Write token refresh logic
  ┗━ [b8c1] Add integration tests
parser    done
```

Each `[label]` is a stable 4-char hex identifier derived from the criterion text. Labels survive reordering and partial checks — **always use labels with `spox check`, never position numbers**.

## Checking off criteria

`spox check <spec> all` marks every remaining open criterion as done in one atomic write, and sets status to `completed`. Use this after finishing all the work on a spec.

```
$ spox check auth all
checked: auth — all 2 open criteria done
status:  auth → completed
```

`spox check <spec> <label>` marks a single criterion by its stable label. The label comes from `spox view -c` output and stays the same even after other criteria are checked off or the list is reordered.

```
$ spox check auth a3f2
checked: auth [a3f2] — Write token refresh logic
```

All check forms require reading the spec first — run `spox view -c <spec>` before checking, since the mtime guard will reject stale checks. After each check, the cache is invalidated, so re-read before the next one.

**Never check multiple criteria in one chained command.** Each check must be a separate tool call:
```
# right
spox check auth a3f2
spox view -c auth
spox check auth b8c1

# wrong — second label resolves from stale cache
spox check auth a3f2 && spox check auth b8c1
```

## Setting status

`spox status <spec> <value>` rewrites the `status:` line in the spec file.

```
$ spox status auth in-progress
auth: draft → in-progress
```

Common values: `draft`, `ongoing`, `completed`, `discarded`.

## Spec file format

Specs are `.md` files inside `.spox/`. The first line must be `status: <value>`, followed by `date: <YYYY-MM-DD>` (the spec's creation date, set once and never edited — used to sort specs newest-first within a status group). Unchecked items (`- [ ] ...`) are open criteria; checked ones (`- [x] ...`) are complete and not shown by `spox view -c`.

```markdown
status: in-progress
date: 2026-03-14

Some notes about this spec.

- [x] Define the data model
- [ ] Write the parser
- [ ] Add tests
```

## Common tasks

**Check current spec status** — run `spox list` or `spox list -c` for the full dashboard, or `spox view -c <spec>` to focus on one spec.

**Initialise spox in a new project** — run `spox init`. This creates `.spox/` and writes `.spox/.format.md`, which is the canonical reference for spec format, naming conventions, and valid statuses. Read it before creating specs in an unfamiliar project.

**Create a new spec** — use the template in `spec-template.md` (in this skill directory), filling in the `date:` line with today's date. Write the filled-in file to `.spox/<name>.md`. Names should be short kebab-case feature identifiers, not task descriptions (`map-grid.md`, not `implement-map.md`).

**Check off all criteria** — run `spox view -c <spec>` to read the spec (required by the mtime guard), then `spox check <spec> all`. Use `spox check <spec> <label>` for partial mid-session completions — the label comes from `spox view -c` output and is stable across checks.

**Update spec status** — run `spox status <spec> <value>`.

**Install the skill into a project** — run `spox skill install`; this embeds the skill at `.claude/skills/spox/SKILL.md` relative to the git root.

## Supporting files in this skill

- `sdd.md` — what Spec-Driven Development is and the intended workflow. Read this when starting work in a spox project for the first time or when the user asks how to use spox.
- `spec-template.md` — blank spec template. Use this when creating a new spec file.

## If spox isn't installed

Direct the user to the spox repo and run `zsh install.zsh`. This builds the release binary and symlinks it into `~/.local/bin/spox`.
