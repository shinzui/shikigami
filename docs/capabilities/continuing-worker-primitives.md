---
type: Capability
title: "Continuing worker session primitives"
description: "Retain ordered assignments, results and event cursors and admit scoped worker control with conditional ownership."
capabilityId: CAP-29
provider: mori://shinzui/shikigami
status: shipped
stability: experimental
since: unreleased
packages: ["shikigami-core", "shikigami-workers", "shikigami-server", "shikigami-migrations"]
interface: ["Shikigami.WorkerSession.Capability", "Shikigami.Flow.Workers", "shikigami workers"]
tags: [continuing-worker-primitives]
generated:
  by: process:shikigami-documentation-refresh
  at: "2026-10-29T00:00:00Z"
requires: [CAP-1]
evidence:
  - kind: module
    resource: "shikigami-core/src/Shikigami/WorkerSession/Capability.hs"
    proves: "One admitted scope and fresh authorization boundary for Flow, model and operator callers."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/WorkerSessionCapabilitySpec.hs"
    proves: "Governed control, retained events and combined follow-up/compaction/replay acceptance."
---

# Continuing worker session primitives

## Provides

Continuing sessions retain ordered mailbox assignments, result references, owner epochs and event cursors beyond terminal workflow journals. Flows, admitted CoordinatingSkills and operator hosts share one command owner. Commands use explicit operation keys, conditional revisions and fresh parent authority.

## Adopt

Use [operator worker commands](../operations/operator-cli.md) for inspection and command syntax. [Behaviors](../user/behaviors.md) explains CoordinatingSkill admission.

Builds on [CAP-1: Typed agent declarations](typed-agent-declarations.md).

## Evidence

- [Capability.hs](../../shikigami-core/src/Shikigami/WorkerSession/Capability.hs): One admitted scope and fresh authorization boundary for Flow, model and operator callers.
- [WorkerSessionCapabilitySpec.hs](../../shikigami-core/test-postgres/Shikigami/WorkerSessionCapabilitySpec.hs): Governed control, retained events and combined follow-up/compaction/replay acceptance.

## Limits

Plan 84 is complete. The [consumer acceptance matrix](../evidence/plan-84/acceptance.md) combines retained mechanics with qualified real objective/checkpoint and workspace providers and native administrative recovery. Protected commands still require enabled tracking, admitted associations and, for repository transfer, the process-backed supervisor. File-only configuration supplies no process fence. Adaptive coordination, integrated live coding and recurrence remain in plans 85–87.

This implementation is experimental and unreleased; no released compatibility promise is asserted.
