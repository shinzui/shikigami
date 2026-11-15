---
type: "Guide"
title: "Routine agents"
description: "Create a routine agent with one command, run it in a repository with one confirmation, schedule it on your machine, and see and fix its runs."
docId: "DOC-24"
tags: ["routine", "local-operator", "schedule", "getting-started"]
generated:
  by: claude-code/claude-opus-5-5
  at: 2026-11-15T22:30:00Z
---

# Routine agents

A routine agent is a declaration of a few lines that does one job in your repositories. It
runs on your machine under the `local-operator` tier ([local operator](local-operator.md)):
you confirm it once, its report goes to `~/.local/state/shikigami/reports`, and every action
is in the record.

## Create and run one

```bash
shikigami-local new repo-digest
```

This writes `~/.config/shikigami/agents/repo-digest.dhall` and
`~/.config/shikigami/agents/skills/repo-digest/SKILL.md`. Describe the task in `SKILL.md`, and
give the declaration the tools it needs:

```dhall
let R = /path/to/shikigami/schema/Routine.dhall

in  R.skill "repo-digest" "/Users/you/.config/shikigami/agents/skills/repo-digest"
      // { capabilityOverlays = R.reads
         , tools = [ R.cli "git" [ [ "log" ], [ "status" ] ] ]
         }
```

Run it in a checkout; the words after the name become the run's `task`:

```bash
cd ~/src/keiro
shikigami-local run repo-digest "focus on the release"
```

The first run asks once, listing the repository, tools and budget; later runs do not, until
you change the declaration. The run ends with the report's path:

```text
report  ~/.local/state/shikigami/reports/repo-digest/4b2ca292-…-0.md
```

`R.coder NAME PROMPT` (or `shikigami-local new NAME --coder`) is a Claude Code coding agent
instead: it works in its own worktree and commits its change on a run branch for you to review.

## Schedule it

Add a schedule, confirm the changed declaration once by hand, then start the local scheduler:

```dhall
// { trigger = R.every "0 7 * * *" }        -- or R.daily 7
```

```bash
shikigami-local run repo-digest            # confirm the new declaration once
shikigami-local up                         # keep it running; --for MINUTES to stop
```

`up` prints what it will run and why it skips the rest:

```text
armed     repo-digest   */2 * * * *   mori://shinzui/keiro
skipped   weekly-audit   0 9 * * 1   no stored approval; run once by hand: shikigami-local run weekly-audit --in DIR
```

An agent runs in the repository of its stored approval. A scheduled run never asks: a
declaration changed since its approval is skipped until you run it by hand again.

## See and fix

```bash
shikigami-local runs              # recent runs: outcome, duration, decisions, report
shikigami-local runs <RUN-ID>     # one run's record and outputs
shikigami-local doctor            # every prerequisite, with the fix for each failure
```
