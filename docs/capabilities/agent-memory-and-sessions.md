---
type: "Capability"
title: "Agent memory and sessions"
description: "Recall prior agent learnings and record session outcomes with configurable automatic memory policy."
capabilityId: "CAP-5"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-agent", "shikigami-migrations"]
interface: ["Shikigami.Agent.Run", "Shikigami.Flow.Capability", "shikigami-agent-run"]
tags: ["agent-memory-and-sessions"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
requires: ["CAP-1"]
evidence:
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs"
    proves: "Never/Always policies, capped fallback recall, principal scope aliases, and crash recovery between record and completion."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/FlowLifecycleSpec.hs"
    proves: "Journaled recall and idempotent explicit remember calls."
  - kind: guide
    resource: "docs/user/memory.md"
    proves: "Declaration policy, activity capture, scope behavior, and database prerequisites."
---

# Agent memory and sessions

## Provides

Shikigami maps runs to dependency-owned sessions and learnings, passes recalled content to the behavior, and completes or fails the session with the run. `OnSuccess`, `Never`, and `Always` govern automatic recording. Explicit Flow memory calls remain independent of that policy. Verified runs use recorded principal scope and may read operator-approved legacy aliases.

## Adopt

Set `memory.recallLimit` and `memory.recordPolicy` in the manifest and use `shikigami-agent-run` or the durable worker. `--from-activity` captures an activity payload as a learning without executing the behavior.

Builds on [CAP-1: Typed agent declarations](typed-agent-declarations.md).

## Evidence

- [AgentWorkflowSpec.hs](../../shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs): Never/Always policies, capped fallback recall, principal scope aliases, and crash recovery between record and completion.
- [FlowLifecycleSpec.hs](../../shikigami-core/test-postgres/Shikigami/FlowLifecycleSpec.hs): Journaled recall and idempotent explicit remember calls.
- [memory.md](../../docs/user/memory.md): Declaration policy, activity capture, scope behavior, and database prerequisites.

## Limits

The recall limit must be between 1 and 1000. Vector recall falls back to active memories in scope when unavailable. `Shared` is a schema alternative without implemented shared recall/access rules. Storage and memory projections are provided by [the memory dependency](mori://shinzui/kioku); this capability describes Shikigami's run integration.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
