---
type: "Capability"
title: "Flow pack composition"
description: "Ship Haskell Flows and service adapters in a pack and select them when building a distribution."
capabilityId: "CAP-37"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "stable"
since: "unreleased"
packages: ["shikigami-core", "kikan-shikigami"]
interface: ["shikigami-core:flow-sdk", "shikigami-core:pack-sdk", "shikigami flows"]
tags: ["flow-pack", "distribution"]
generated:
  by: "process:codex-cli"
  at: "2026-11-21T13:31:35Z"
requires: ["CAP-4"]
evidence:
  - kind: test
    resource: "shikigami-core/test/Shikigami/FlowPackSpec.hs"
    proves: "Registry composition, ordering and collision diagnostics."
  - kind: module
    resource: "packs/kikan-shikigami/src-shared/Packs.hs"
    proves: "The common distribution list of the binding and four use-case packs."
---

# Flow pack composition

## Provides

A distribution composes packs at executable startup. Packs contribute Flows, interpreters, decision programs, settings and service adapters. The stock builtin pack supplies `adaptive-delivery` and `run-declared-tool`. The Kikan distribution adds the binding, examples, watchdog, initiative and practice-review packs.

## Adopt

Follow [writing a pack](../user/flows.md#flow-packs) and inspect the executable with `flows`. Check the SDK and ownership rules with `just kernel-fitness` and the public contract with `just api-baseline`.

Requires [CAP-4](durable-agent-flows.md).

## Evidence

- [FlowPackSpec.hs](../../shikigami-core/test/Shikigami/FlowPackSpec.hs) covers registry composition, ordering and collision diagnostics.
- [Packs.hs](../../packs/kikan-shikigami/src-shared/Packs.hs) covers the common distribution list of the binding and four use-case packs.

## Limits

A declaration selects a Flow installed in the running executable. Each new pack requires a composed build. SDK compatibility follows the [API baseline](../architecture/api-baseline.md). The Nix deployment roles package the stock composition.
