---
type: "Capability"
title: "Durable agent runs and Flows"
description: "Resume agent lifecycles and composed Haskell Flows from journaled steps after suspension or restart."
capabilityId: "CAP-4"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-workers", "shikigami-migrations", "flow-pack-examples", "kikan-shikigami"]
interface: ["Shikigami.Agent.Workflow", "Shikigami.Flow", "Shikigami.Flow.Pack", "Shikigami.Flow.Builtin", "shikigami-worker", "shikigami render-lifecycle"]
tags: ["durable-agent-flows"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
requires: ["CAP-1"]
evidence:
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs"
    proves: "Completed-step replay, crash recovery, transient retry, and permanent failure journaling."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/FlowLifecycleSpec.hs"
    proves: "Registered Flow execution, suspension, acknowledgement timeout, and replay without duplicate memory or outbox rows."
  - kind: module
    resource: "shikigami-core/src/Shikigami/Flow.hs"
    proves: "The FlowDef type and the restricted effect surface available to a Flow body."
  - kind: module
    resource: "shikigami-core/src/Shikigami/Flow/Builtin.hs"
    proves: "The builtin pack: the kernel's own flows, composed by every executable."
---

# Durable agent runs and Flows

## Provides

A durable run journals lifecycle work under its run identity and resumes through the shared workflow registry. A compiled Flow can checkpoint pure results and use replay-safe memory, sink, acknowledgement, delegation, and routing interpreters. Each registered flow carries a lifecycle diagram that the administrative command renders.

The effect surface also includes [governed typed decisions](typed-flow-decisions.md),
with finite slot inventories, pinned program/model state, retained result codecs,
and durable actual-attempt evidence.

## Adopt

The durable run, the Flow runner and the builtin pack (`run-declared-tool`, `adaptive-delivery`) are kernel. A use-case Flow ships in a flow pack and is composed into an executable by a distribution such as `packs/kikan-shikigami`; it is not added to the core. Declare `Behavior.Flow` with the name of a flow the executable was composed with, following [Flows](../user/flows.md#flow-packs). Operate the migrated database and workflow worker. Flow body changes must follow [workflow versioning](../workflow-versioning.md).

Builds on [CAP-1: Typed agent declarations](typed-agent-declarations.md).

## Evidence

- [AgentWorkflowSpec.hs](../../shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs): Completed-step replay, crash recovery, transient retry, and permanent failure journaling.
- [FlowLifecycleSpec.hs](../../shikigami-core/test-postgres/Shikigami/FlowLifecycleSpec.hs): Registered Flow execution, suspension, acknowledgement timeout, and replay without duplicate memory or outbox rows.
- [Flow.hs](../../shikigami-core/src/Shikigami/Flow.hs): The FlowDef type and the restricted effect surface available to a Flow body.
- [Builtin.hs](../../shikigami-core/src/Shikigami/Flow/Builtin.hs): The builtin pack: the kernel's own flows, composed by every executable.

## Limits

Dhall selects compiled flows; it cannot load arbitrary Haskell at runtime, and a manifest naming a flow of a pack the executable was not composed with is refused at validation and worker boot. The lifecycle diagram is descriptive and does not own execution state. A journal records completed steps; it does not make external HTTP exactly-once or independently checkpoint every turn inside a synchronous Skill tool loop.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.

## Recoverable execution and continuing sessions

Leaf Skill runs now await a separate [durable execution child](recoverable-skill-execution.md)
that retains model/tool operations. [Continuing worker primitives](continuing-worker-primitives.md)
retain assignments and results across generations. Configured objective/checkpoint and fenced workspace providers support governed handoffs. Changes to journaled steps must obey the durable wire baseline; see [workflow versioning](../workflow-versioning.md).
