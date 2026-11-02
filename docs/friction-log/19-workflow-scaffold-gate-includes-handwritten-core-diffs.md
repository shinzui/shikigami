---
type: Friction Entry
title: "Workflow scaffold gate includes handwritten core diffs"
description: "The workflow scaffold gate treats all uncommitted core-source changes as stale generated output, requiring a commit before compatibility verification."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-29T21:48:28Z"
frictionId: FRIC-19
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Commit the verified implementation and rerun the workflow gate on that committed source; do not regenerate or edit unchanged generated files."
resolution: "Run the scaffold gate against committed source; its whole-core drift check remains the reviewed house contract."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-02T18:43:37Z"
    change: "Triage the observed qualification constraint with its retained bounded workaround."
---
# Workflow scaffold gate includes handwritten core diffs

## Attempted

Run nix develop --no-write-lock-file -c just keiro-gate 41cd161 after the core, worker and PostgreSQL candidate suites passed.

## Encountered

Scaffolding reported generated artifacts unchanged, but the gate printed handwritten Workspace.Process/Provider and Execution.Store diffs and failed as stale generated output.

```text
keiro-scaffold: the committed generated layer is out of date; commit the regeneration
```

## Workaround

Commit the verified implementation and rerun the workflow gate on that committed source; do not regenerate or edit unchanged generated files.
