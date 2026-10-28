---
type: Friction Entry
title: "Selection migration inherited executable output from the recipe comment"
description: "During EP-2 the migration recipe embedded schema-check output into new SQL, stopping the PostgreSQL suite until the unapplied migration was repaired."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-28T06:26:55Z"
frictionId: FRIC-11
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/82-pin-governed-execution-settings-for-agent-assignments.md"
workaround: "Repair the unapplied selection SQL; EP-3 subsequently fixed the shared recipe and verified it in an isolated directory."
resolution: "EP-3 removed the recipe command substitution and verified a fresh generated migration contains only SQL comments. The already committed selection migration had been repaired before its first successful disposable application."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T06:27:18Z"
    change: "Record the separately affected EP-2 occurrence after the producer was identified during EP-3."
---
# Selection migration inherited executable output from the recipe comment

## Attempted

Create the selection migration with just new-migration and initialize its disposable PostgreSQL suite.

## Encountered

PostgreSQL rejected an uncommented migration-schema-isolation line with SQLSTATE 42601. EP-3 recurrence later identified command substitution in the unquoted recipe template as the producer.

```text
ServerError 42601: syntax error at or near migration
```

## Workaround

Repair the unapplied selection SQL; EP-3 subsequently fixed the shared recipe and verified it in an isolated directory.
