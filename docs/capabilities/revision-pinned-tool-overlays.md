---
type: "Capability"
title: "Revision-pinned tool overlays"
description: "Resolve additive Skill tools against an operator catalog, acquire exact-revision leases, and release them on every exit."
capabilityId: "CAP-12"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-agent"]
interface: ["Shikigami.Capability.Catalog", "Shikigami.Capability.Provider", "Shikigami.Agent.Capability.Workspace", "capabilityOverlays"]
tags: ["revision-pinned-tool-overlays"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
requires: ["CAP-3", "CAP-7"]
evidence:
  - kind: test
    resource: "shikigami-core/test/Shikigami/CapabilityOverlaySpec.hs"
    proves: "Pure admission refuses duplicate/unknown requests and unsupported behavior or operation classes."
  - kind: test
    resource: "shikigami-core/test/Shikigami/CapabilityProviderSpec.hs"
    proves: "Exact descriptor matching, partial acquisition cleanup, cancellation, and release failure behavior."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs"
    proves: "A retry reacquires the pinned revision while a new run selects a changed catalog."
  - kind: test
    resource: "shikigami-agent/test/Shikigami/Agent/Capability/WorkspaceSpec.hs"
    proves: "Bounded workspace observation and safe path handling."
---

# Revision-pinned tool overlays

## Provides

A Skill opts into catalogued capabilities; pure admission selects immutable public descriptors and the durable path journals them. Provider lookup verifies the exact revision and advertised semantics, acquires run-scoped tools, and releases leases in reverse acquisition order. The portable package includes a bounded `workspace.read` observation provider for embedding.

## Adopt

Compose an operator catalog, provider registry, and exact-action authorizer and add requested IDs to `capabilityOverlays`. Runtime tools supplement the base registry after name-conflict checks. Use the workspace provider only with an explicit workspace and authorization.

Builds on [CAP-3: Program and Skill execution](program-and-skill-execution.md), [CAP-7: Exact external-action authorization](exact-action-authorization.md).

## Evidence

- [CapabilityOverlaySpec.hs](../../shikigami-core/test/Shikigami/CapabilityOverlaySpec.hs): Pure admission refuses duplicate/unknown requests and unsupported behavior or operation classes.
- [CapabilityProviderSpec.hs](../../shikigami-core/test/Shikigami/CapabilityProviderSpec.hs): Exact descriptor matching, partial acquisition cleanup, cancellation, and release failure behavior.
- [AgentWorkflowSpec.hs](../../shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs): A retry reacquires the pinned revision while a new run selects a changed catalog.
- [WorkspaceSpec.hs](../../shikigami-agent/test/Shikigami/Agent/Capability/WorkspaceSpec.hs): Bounded workspace observation and safe path handling.

## Limits

Only Skill behaviors admit overlays. Durable overlays allow observation operations, not arbitrary mutation. The empty default runtime installs no providers, and current one-off CLI commands use the deny-all action authorizer, so `--workspace` alone cannot grant reads. Workspace editing, validation commands, Git mutation, and a live Kubernetes observation provider are not supplied.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
