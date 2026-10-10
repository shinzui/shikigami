---
type: "Capability"
title: "Exact external-action authorization"
description: "Require a verified authorization decision immediately before acquiring providers, calling tools, or delivering protected sinks."
capabilityId: "CAP-7"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-workers"]
interface: ["Shikigami.Action.Authorization", "authorization.actions.mode", "Shikigami.Capability.Provider"]
tags: ["exact-action-authorization"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
requires: ["CAP-6"]
evidence:
  - kind: module
    resource: "shikigami-core/src/Shikigami/Action/Authorization.hs"
    proves: "Production authorizer, locally checked decision coordinates, distinct failure classes, and deny-all default."
  - kind: test
    resource: "shikigami-core/test/Shikigami/BehaviorToolSpec.hs"
    proves: "An exact tool denial prevents the leased tool callback from running."
  - kind: guide
    resource: "docs/operations/action-authorization.md"
    proves: "Trust configuration, boundary gate order, outages, revocation, and key rotation."
---

# Exact external-action authorization

## Provides

Shikigami submits a concrete principal/action/resource request through the configured policy client and retains bounded decision coordinates after proof verification. Provider acquisition and each logical tool call are separate checks. Sink enqueue and publication check lifecycle, sink-kind permission, and the exact target. Policy denial, unavailable authorization, and rejected proofs remain distinguishable.

## Adopt

Configure the complete action-authorization trust group documented in [Per-action authorization operations](../operations/action-authorization.md). Supply the resulting authorizer at each execution boundary.

Builds on [CAP-6: Principal lifecycle and continuity](principal-lifecycle-and-continuity.md).

## Evidence

- [Authorization.hs](../../shikigami-core/src/Shikigami/Action/Authorization.hs): Production authorizer, locally checked decision coordinates, distinct failure classes, and deny-all default.
- [BehaviorToolSpec.hs](../../shikigami-core/test/Shikigami/BehaviorToolSpec.hs): An exact tool denial prevents the leased tool callback from running.
- [action-authorization.md](../../docs/operations/action-authorization.md): Trust configuration, boundary gate order, outages, revocation, and key rotation.

## Limits

The default and current one-off composition roots deny protected actions. A lease, manifest, or sink-kind grant does not confer exact-action permission. Deployment requires [the policy service](mori://shinzui/kikan-en), [the credential issuer](mori://shinzui/shomei), and configured verifier trust; this repository supplies the enforcing client boundaries.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
