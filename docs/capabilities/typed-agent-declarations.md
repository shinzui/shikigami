---
type: "Capability"
title: "Typed agent declarations"
description: "Load typed Dhall manifests with identity, behavior, triggers, sinks, memory, delegation, and overlay policy."
capabilityId: "CAP-1"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
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

## Adopt

Start with [Writing Agents](../user/writing-agents.md), then run `shikigami validate agents/heartbeat.dhall`. Select a behavior the build actually registers.

## Evidence

- [AgentLoaderSpec.hs](../../shikigami-core/test/Shikigami/AgentLoaderSpec.hs): Defaults, explicit policy, JSON round trips, malformed declarations, and strict directory loading.
- [heartbeat.dhall](../../agents/heartbeat.dhall): A minimal executable declaration using schema record completion.

## Limits

Parsing does not establish executability or authorization. `Deterministic` is accepted by the schema but its runner returns `UnsupportedBehavior`. `ShikumiProgram` enrichment, grounding, and `enabledBy` fields are metadata unless the selected program implements them.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
