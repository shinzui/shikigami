---
type: Capability
title: "Recoverable Skill execution"
description: "Retain protected model and tool operations, compose bounded harness policies and recover accepted durable work."
capabilityId: CAP-28
provider: mori://shinzui/shikigami
status: shipped
stability: experimental
since: unreleased
packages: ["shikigami-core", "shikigami-agent", "shikigami-workers", "shikigami-server", "shikigami-migrations"]
interface: ["Shikigami.Execution.Start", "Shikigami.Execution.Store", "shikigami executions inspect"]
tags: [recoverable-skill-execution]
generated:
  by: process:shikigami-documentation-refresh
  at: "2026-10-29T00:00:00Z"
requires: [CAP-1]
evidence:
  - kind: module
    resource: "shikigami-core/src/Shikigami/Execution/Executor.hs"
    proves: "Fenced submit/observe dispatch with retained accepted input and attempt settlement."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/ExecutionTranscriptSpec.hs"
    proves: "Protected replay, accepted operation recovery and retained transcript semantics."
---

# Recoverable Skill execution

## Provides

New leaf Skills and conversation turns freeze instructions, input, model binding, tool menu and policy before the execution child starts. Accepted operations and actual attempts have separate identities. Safe recovery, output repair, compaction, summaries and human permission requirements compose under operator ceilings.

## Adopt

Follow [durable execution policies](../operations/durable-execution.md). Inspect bounded metadata with `shikigami executions inspect EXECUTION --json`.

Builds on [CAP-1: Typed agent declarations](typed-agent-declarations.md).

## Evidence

- [Executor.hs](../../shikigami-core/src/Shikigami/Execution/Executor.hs): Fenced submit/observe dispatch with retained accepted input and attempt settlement.
- [ExecutionTranscriptSpec.hs](../../shikigami-core/test-postgres/Shikigami/ExecutionTranscriptSpec.hs): Protected replay, accepted operation recovery and retained transcript semantics.

## Limits

The no-database behavior command uses an ephemeral recording. Unknown unsafe effects require reconciliation; a retry does not erase the earlier reservation. Protected transcript bodies are excluded from inspection. No mutable repository provider or adaptive coordinator is supplied.

This implementation is experimental and unreleased; no released compatibility promise is asserted.
