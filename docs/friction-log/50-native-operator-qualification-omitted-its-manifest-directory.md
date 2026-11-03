---
type: Friction Entry
title: "Native operator qualification omitted its manifest directory"
description: "The workspace fixture configured database, identity and fencing services but relied on the relative default agents directory, so actual administrative recovery failed before reaching the configured provider."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-03T19:45:14Z"
frictionId: FRIC-50
status: "resolved"
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md"
workaround: "Set agents.directory to the explicit copied fixture manifest directory in the generated guest configuration."
resolution: "Generate agents.directory from the explicit copied guest source root. The retry passes all nine native ownership/restart cases, including the original and duplicate administrative established-handoff replies."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-03T19:48:39Z"
    change: "Status set to resolved."
---
# Native operator qualification omitted its manifest directory

## Attempted

Run the actual operator recovery path in the disposable Apple ownership fixture.

## Encountered

The successor stage exited with does not exist while loading the default relative agents directory.

```text
Six native ownership/provisioning cases passed; continuing-successor.log reported does not exist before an operator reply.
```

## Workaround

Set agents.directory to the explicit copied fixture manifest directory in the generated guest configuration.
