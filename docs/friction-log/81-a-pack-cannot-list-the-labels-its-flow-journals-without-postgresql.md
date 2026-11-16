---
type: Friction Entry
title: "A pack cannot list the labels its flow journals without PostgreSQL"
description: "keiro's Workflow effect has no store-free interpreter, so the flow pack's golden label inventory needs a migrated database in a package test."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-16T04:43:05Z"
frictionId: FRIC-81
status: "promoted"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/keiro"
affectedVersion: "0.22.0.0"
plan: "docs/plans/130-move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check.md"
workaround: "The pack test runs each branch under runWorkflowWith on a fresh migrated database (shikigami-migrations:test-support) and reads loadStepIndex; kernel capabilities are recording interpreters. Raised upstream as mori://shinzui/keiro/okf/improvement-requests/concepts/IR-61."
tags:
  - "flow-packs"
promotedTo: "mori://shinzui/keiro/okf/improvement-requests/concepts/IR-61"
amended:
  - by: "claude-code/claude-fable-5-2"
    at: "2026-11-16T04:43:06Z"
    change: "Status set to promoted."
---
# A pack cannot list the labels its flow journals without PostgreSQL

## Attempted

Writing packs/flow-pack-examples/test/Main.hs: run atRiskCustomerFlow over recording interpreters with effectful's interpret, matching Keiro.Workflow's Step constructor to record step labels.

## Encountered

Keiro.Workflow exports the Workflow effect without constructors, and runWorkflow and runWorkflowWith require Store, so the body cannot run without a database.

```text
test/Main.hs:161:3: error: [GHC-76037] Not in scope: data constructor 'Keiro.Step'. Note: The module 'Keiro.Workflow' does not export 'Step'.
```

## Workaround

The pack test runs each branch under runWorkflowWith on a fresh migrated database (shikigami-migrations:test-support) and reads loadStepIndex; kernel capabilities are recording interpreters. Raised upstream as mori://shinzui/keiro/okf/improvement-requests/concepts/IR-61.
