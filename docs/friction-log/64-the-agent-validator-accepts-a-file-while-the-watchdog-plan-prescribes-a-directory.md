---
type: Friction Entry
title: "The agent validator accepts a file while the watchdog plan prescribes a directory"
description: "Plan 112 validation commands pass an agents directory to a CLI whose validate subcommand accepts one manifest file."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-06T16:42:55Z"
frictionId: FRIC-64
status: "resolved"
impact: nuisance
kind: documentation
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami/plans/112-run-the-watchdog-as-a-scheduled-flow-agent-with-its-own-principal-allowance-and-sinks"
plan: "docs/plans/112-run-the-watchdog-as-a-scheduled-flow-agent-with-its-own-principal-allowance-and-sinks.md"
workaround: "Validate agents/proof/watchdog.dhall and correct the plan command."
resolution: "Corrected plan 112 to validate the watchdog manifest file and validated all seventeen proof manifests individually with the built CLI."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-06T16:43:34Z"
    change: "The documented validation command now matches the existing file-only CLI contract."
---
# The agent validator accepts a file while the watchdog plan prescribes a directory

## Attempted

cabal run shikigami -- validate agents/proof

## Encountered

The validator attempted to open the directory as a file and exited nonzero.

```text
agents/proof: openFile: inappropriate type (is a directory); help: shikigami validate FILE
```

## Workaround

Validate agents/proof/watchdog.dhall and correct the plan command.
