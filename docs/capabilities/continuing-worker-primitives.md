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
    proves: "Governed control, retained events and replay using explicit deterministic providers."
---

# Continuing worker session primitives

## Provides

Continuing sessions retain ordered mailbox assignments, result references, owner epochs and event cursors beyond terminal workflow journals. Flows, admitted CoordinatingSkills and operator hosts share one command owner. Commands use explicit operation keys, conditional revisions and fresh parent authority.

## Adopt

Use [operator worker commands](../operations/operator-cli.md) for inspection and command syntax. [Behaviors](../user/behaviors.md) explains CoordinatingSkill admission.

Builds on [CAP-1: Typed agent declarations](typed-agent-declarations.md).

## Evidence

- [Capability.hs](../../shikigami-core/src/Shikigami/WorkerSession/Capability.hs): One admitted scope and fresh authorization boundary for Flow, model and operator callers.
- [WorkerSessionCapabilitySpec.hs](../../shikigami-core/test-postgres/Shikigami/WorkerSessionCapabilitySpec.hs): Governed control, retained events and replay using explicit deterministic providers.

## Limits

Plan 84 remains in progress. Deterministic checkpoint/ownership adapters prove mechanics; real objective/checkpoint and workspace fences remain completion gates. Default CLI send/interrupt/integrate/transfer refuses work requiring these absent providers. This is not full adaptive delivery.

This implementation is experimental and unreleased; no released compatibility promise is asserted.
