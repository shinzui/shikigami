---
type: Capability
title: "Repository catalog admission"
description: "Resolve only operator-approved canonical repository identities and immutable base revisions."
capabilityId: CAP-30
provider: mori://shinzui/shikigami
status: shipped
stability: experimental
since: unreleased
packages: ["shikigami-core"]
interface: ["Shikigami.Workspace.Catalog"]
tags: [repository-catalog-admission]
generated:
  by: process:shikigami-documentation-refresh
  at: "2026-10-29T00:00:00Z"
requires: [CAP-1]
evidence:
  - kind: module
    resource: "shikigami-core/src/Shikigami/Workspace/Catalog.hs"
    proves: "Pure opaque resolution with no filesystem I/O or caller-selected host paths."
  - kind: test
    resource: "shikigami-core/test/Shikigami/WorkspaceCatalogSpec.hs"
    proves: "Rejects unknown/duplicate identities, branches, unapproved commits and malformed configuration."
---

# Repository catalog admission

## Provides

The pure library validates operator repository policies and resolves canonical Mori project identities to an opaque configured source, approved immutable base and policy revision. It refuses aliases and mutable revision selectors.

## Adopt

Construct `RepositoryPolicy` values in a trusted host, validate with `mkWorkspaceCatalog`, then call `resolveRepository`. The source module documents the closed input and opaque result.

Builds on [CAP-1: Typed agent declarations](typed-agent-declarations.md).

## Evidence

- [Catalog.hs](../../shikigami-core/src/Shikigami/Workspace/Catalog.hs): Pure opaque resolution with no filesystem I/O or caller-selected host paths.
- [WorkspaceCatalogSpec.hs](../../shikigami-core/test/Shikigami/WorkspaceCatalogSpec.hs): Rejects unknown/duplicate identities, branches, unapproved commits and malformed configuration.

## Limits

The catalog validates policy and resolves an approved target. The [workspace runtime](../operations/workspaces.md) owns allocation, edits and process fencing. Personal runs use [local repository grants](local-operator-runs.md).

This implementation is experimental and unreleased; no released compatibility promise is asserted.
