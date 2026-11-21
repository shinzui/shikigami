---
type: "Capability"
title: "Typed agent declarations"
description: "Load typed Dhall manifests with identity, behavior, manual or automatic triggers, registered outputs, tools, memory and delegation."
capabilityId: "CAP-1"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "stable"
since: "unreleased"
packages: ["shikigami-core", "shikigami-server"]
interface: ["schema/Agent.dhall", "Shikigami.Agent.Loader", "shikigami validate"]
tags: ["typed-agent-declarations"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
evidence:
  - kind: test
    resource: "shikigami-core/test/Shikigami/AgentLoaderSpec.hs"
    proves: "Defaults, explicit policy, JSON round trips, malformed declarations, and strict directory loading."
  - kind: example
    resource: "agents/heartbeat.dhall"
    proves: "A minimal executable declaration using schema record completion."
---

# Typed agent declarations

## Provides

A consumer declares an agent in Dhall and loads it through the same schema and loader used by runtime entry points. Directory loading preserves failed-manifest diagnostics, supports strict startup, and selects enabled declarations. The loader retains policy fields rather than discarding them during JSON conversion.

`decisionModels` defaults to an empty list and names the operator aliases the
agent permits for [typed Flow decisions](typed-flow-decisions.md). The HTTP catalog
retains disabled declarations for inspection without admitting their execution.

## Adopt

Start with [Writing Agents](../user/writing-agents.md), then run `shikigami validate agents/proof/portable-note.dhall`. Select a behavior the build actually registers.

## Evidence

- [AgentLoaderSpec.hs](../../shikigami-core/test/Shikigami/AgentLoaderSpec.hs): Defaults, explicit policy, JSON round trips, malformed declarations, and strict directory loading.
- [heartbeat.dhall](../../agents/heartbeat.dhall): A minimal executable declaration using schema record completion.

## Limits

Parsing does not establish executability or authorization. `ShikumiProgram` enrichment and grounding fields are metadata unless the selected program implements them.

The declaration schema and its journal encoding are stable surfaces under the [API baseline](../architecture/api-baseline.md). A declaration may omit `trigger` (manual) and `outputs` (use the composition default). The heartbeat example uses a Kikan helper and requires the Kikan validator for its output.

## Assignment policy additions

The canonical declaration also exposes `execution` and `harness`, documented in
[Writing agents](../user/writing-agents.md). They support
[assignment selection](assignment-execution-selection.md) and
[recoverable Skill execution](recoverable-skill-execution.md). `CoordinatingSkill`
requires an admitted scope for [worker control](continuing-worker-primitives.md);
its declaration alone creates no authority.
