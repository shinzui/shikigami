---
type: Friction Entry
title: "Migration template executes the schema check inside SQL"
description: "The migration recipe expands backticks in its SQL comment, embedding command output as executable SQL and requiring diagnosis and repair."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-28T05:48:33Z"
frictionId: FRIC-10
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md"
workaround: "Repair only the new unapplied SQL and remove command substitution from the recipe comment."
resolution: "Removed command substitution from the migration comment. An isolated invocation now emits only SQL comments, and the new unapplied migration was repaired."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T05:49:49Z"
    change: "The isolated migration recipe probe passed; applied migration bytes are unchanged."
---
# Migration template executes the schema check inside SQL

## Attempted

just new-migration execution-transcripts-and-accepted-operations

## Encountered

The newly generated SQL contains an uncommented migration-schema-isolation output line; the same template corrupted the EP-2 migration before its first disposable application.

```text
migration-schema-isolation: application SQL is schema-qualified; vendored PGMQ SQL has no session path mutation before commit.
```

## Workaround

Repair only the new unapplied SQL and remove command substitution from the recipe comment.
