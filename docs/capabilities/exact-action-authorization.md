---
type: "Capability"
title: "Exact external-action authorization"
description: "Require a verified authorization decision immediately before acquiring providers, calling tools, or delivering protected sinks."
capabilityId: "CAP-7"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-agent", "kikan-shikigami-binding"]
interface: ["Shikigami.Authority", "authorization.actions.mode", "Shikigami.Capability.Provider"]
tags: ["exact-action-authorization"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
requires: ["CAP-6"]
evidence:
  - kind: module
    resource: "shikigami-core/src/Shikigami/Authority.hs"
    proves: "Kernel action vocabulary, fail-closed authority and recording of decisions."
  - kind: test
    resource: "shikigami-core/test/Shikigami/BehaviorToolSpec.hs"
    proves: "An exact tool denial prevents the leased tool callback from running."
  - kind: guide
    resource: "docs/operations/action-authorization.md"
    proves: "Trust configuration, boundary gate order, outages, revocation, and key rotation."
---

# Exact external-action authorization

## Provides

Every protected effect passes its principal, action and target to the run’s kernel authority. The local adapter checks the operator grant. The Kikan binding verifies the policy service’s decision proof. Provider acquisition and each logical tool call are separate checks. Sink enqueue and publication check lifecycle, sink-kind permission, and the exact target. Policy denial, unavailable authorization, and rejected proofs remain distinguishable.

## Adopt

For personal repositories, configure [local operator grants](local-operator-runs.md). For the Kikan distribution, configure the trust group in [per-action authorization operations](../operations/action-authorization.md). Inspect [the action record](run-action-record.md) to see who decided.

Builds on [CAP-6: Principal lifecycle and continuity](principal-lifecycle-and-continuity.md).

## Evidence

- [Authority.hs](../../shikigami-core/src/Shikigami/Authority.hs): Kernel action vocabulary, fail-closed authority and recording of decisions.
- [BehaviorToolSpec.hs](../../shikigami-core/test/Shikigami/BehaviorToolSpec.hs): An exact tool denial prevents the leased tool callback from running.
- [action-authorization.md](../../docs/operations/action-authorization.md): Trust configuration, boundary gate order, outages, revocation, and key rotation.

## Limits

An unconfigured deployment authority denies protected actions. The binding maps capability connections and tool invocations to Kikan-En. Declared tools require the local-operator tier. The binding refuses coding-agent launches because Kikan-En lacks a launch action. The Kikan adapter requires [the policy service](mori://shinzui/kikan-en), [the credential issuer](mori://shinzui/shomei), and configured verifier trust; this repository supplies the enforcing client boundaries.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
