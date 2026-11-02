---
type: Friction Entry
title: "Execution fixture driver counted superseded attempts"
description: "The shared execution child driver treated superseded attempts as current and stopped the conversation lost-acknowledgement qualification."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-02T08:43:55Z"
frictionId: FRIC-40
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/101-make-objective-capabilities-durable-for-agents-and-conversations.md"
workaround: "Use Execution.Attempt.logicalAttempt in the shared fixture driver, matching the production driver and the transcript fixture."
resolution: "The shared child driver now selects Execution.Attempt.logicalAttempt; real conversation creation and lost-acknowledgement recovery pass."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-02T08:45:36Z"
    change: "Resolved the helper assumption and qualified recovery through the actual conversation workflow."
---
# Execution fixture driver counted superseded attempts

## Attempted

Run ObjectiveWorkflowSpec through ExecutionSelectionWorkflowSpec.driveExecutionChild after a committed tool loses acknowledgement.

## Encountered

The helper excluded only abandoned attempts, so an original superseded attempt and its replacement were counted together.

```text
driver child has no accepted attempt
```

## Workaround

Use Execution.Attempt.logicalAttempt in the shared fixture driver, matching the production driver and the transcript fixture.
