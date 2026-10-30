---
type: Friction Entry
title: "Linux fixture locale rejects the UTF-8 declaration schema"
description: "The normal parent fixture reaches declaration loading under an ASCII guest locale and rejects the checked-in UTF-8 Dhall schema before admission."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-30T13:52:23Z"
frictionId: FRIC-28
status: "resolved"
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Set LANG and LC_ALL to C.UTF-8 for the trusted fixture controller; repository payloads retain their separately cleared policy environment."
resolution: "C.UTF-8 lets the trusted controller load the unchanged UTF-8 schema; the focused native parent/child upgrade passes all three provisioning/workflow cases with exact commit and validation evidence."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-30T13:57:22Z"
    change: "Qualify UTF-8 controller setup without changing the repository payload environment."
---
# Linux fixture locale rejects the UTF-8 declaration schema

## Attempted

Run the normal durable-workflow fixture after the thirteen native process/Git cases passed.

## Encountered

Agent.Loader failed decoding the declaration schema at a UTF-8 punctuation character under the guest locale.

```text
schema/Agent.dhall: hGetContents: invalid argument (cannot decode byte sequence starting from 226); /tmp/shikigami-workspace-run.EzDyDu/evidence/workflow-admit.log
```

## Workaround

Set LANG and LC_ALL to C.UTF-8 for the trusted fixture controller; repository payloads retain their separately cleared policy environment.
