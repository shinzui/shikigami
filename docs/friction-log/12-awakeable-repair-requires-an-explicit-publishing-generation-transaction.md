---
type: Friction Entry
title: "Awakeable repair requires an explicit publishing-generation transaction"
description: "Keiro completed-wake repair selects the current generation, requiring application-owned fixed-generation transactions for rotating workflows."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-28T15:38:22Z"
frictionId: FRIC-12
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/keiro/packages/keiro"
affectedVersion: "0.18.0.0"
plan: "docs/plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md"
workaround: "Compose prepareJournalAppend with the recorded generation and completeAwakeableTx in one transaction; carry an optional timer generation and verify legacy tokens against the live allocation."
---
# Awakeable repair requires an explicit publishing-generation transaction

## Attempted

Publish conversation input and idle-timeout wakes after continueAsNew without changing the owner generation of an old token.

## Encountered

signalAwakeableFrom obtains currentGeneration even when repairing a completed token, so an old idle timer can append an orphan wake to a successor journal.

```text
Selected Keiro 0.18.0.0 signalAwakeableFrom repairs completed rows through currentGeneration; the prior conversation idle handler also called appendJournalEntryReturningId without an explicit generation.
```

## Workaround

Compose prepareJournalAppend with the recorded generation and completeAwakeableTx in one transaction; carry an optional timer generation and verify legacy tokens against the live allocation.
