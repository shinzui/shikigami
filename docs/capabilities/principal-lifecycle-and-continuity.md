---
type: "Capability"
title: "Principal lifecycle and continuity"
description: "Gate runs on a validated directory snapshot and preserve principal-based memory and grants across presentation renames."
capabilityId: "CAP-6"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-server"]
interface: ["Shikigami.Directory", "Shikigami.Agent.Principal", "shikigami agents list", "shikigami agents sync"]
tags: ["principal-lifecycle-and-continuity"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
requires: ["CAP-1"]
evidence:
  - kind: test
    resource: "shikigami-core/test/Shikigami/DirectorySpec.hs"
    proves: "Fail-closed initial snapshots, pause/reactivation, identity matching, and retention of the last valid refresh."
  - kind: test
    resource: "shikigami-server/test/Shikigami/Server/AgentsSpec.hs"
    proves: "Joined fleet inspection and explicit, conflict-aware rename alias reconciliation."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs"
    proves: "Principal-scoped recall and grants survive storage reopening and presentation rename."
---

# Principal lifecycle and continuity

## Provides

A configured directory admits active principals, skips paused or deactivated agents, rejects unknown identities, and refuses invalid initial snapshots. Refresh keeps the last valid snapshot on invalid input. Operator commands report declaration/principal joins and reconcile explicit aliases without creating replacement principals or granting new authority.

## Adopt

Configure the file-backed directory snapshot and declared principal identity. Use [operator commands](../operations/operator-cli.md) to inspect joins and reconcile existing persisted state.

Builds on [CAP-1: Typed agent declarations](typed-agent-declarations.md).

## Evidence

- [DirectorySpec.hs](../../shikigami-core/test/Shikigami/DirectorySpec.hs): Fail-closed initial snapshots, pause/reactivation, identity matching, and retention of the last valid refresh.
- [AgentsSpec.hs](../../shikigami-server/test/Shikigami/Server/AgentsSpec.hs): Joined fleet inspection and explicit, conflict-aware rename alias reconciliation.
- [AgentWorkflowSpec.hs](../../shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs): Principal-scoped recall and grants survive storage reopening and presentation rename.

## Limits

This is a validated snapshot integration, not a live Meibo HTTP client. Directory-disabled mode deliberately uses compatibility identity. Conversation indexing retains a name-keyed compatibility scope. Automatic directory ownership routing and unrestricted alias inference are not provided.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
