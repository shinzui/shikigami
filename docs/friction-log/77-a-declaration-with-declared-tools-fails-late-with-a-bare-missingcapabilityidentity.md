---
type: Friction Entry
title: "A declaration with declared tools fails late with a bare MissingCapabilityIdentity"
description: "shikigami-agent-run refuses a declaration whose tools become overlays when it has no identity, but only after the grant prompt and with an error that names neither the field nor the fix, which cost a rerun in EP-3 and again in EP-4."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-16T00:05:09Z"
frictionId: FRIC-77
status: "resolved"
impact: slowdown
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/129-execute-dhall-declared-playbooks-with-fan-out-approval-gates-and-learning-capture.md"
tags:
  - "declared-tools"
  - "error-messages"
resolution: "The local-operator composition refuses a declaration that requests capabilities without an identity before the grant prompt, naming the capabilities and the identity field to add (shikigami-agent Trust.hs)."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-16T00:06:12Z"
    change: "Status set to resolved."
---
# A declaration with declared tools fails late with a bare MissingCapabilityIdentity

## Attempted

shikigami-agent-run --agent agents/playbooks/package-paths-agent.dhall (declared mori tool) under trust.tier=local-operator

## Encountered

After 'Grant this declaration? y' the run printed 'agent-run: MissingCapabilityIdentity' and exited; the same happened for repo-inventory in EP-3.

```text
agent-run: MissingCapabilityIdentity
```
