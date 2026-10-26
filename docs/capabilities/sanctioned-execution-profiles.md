---
type: "Capability"
title: "Sanctioned execution profile pinning"
description: "Resolve an immutable execution policy before a run and retain its exact provider, model, and option constraints on replay."
capabilityId: "CAP-13"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-migrations"]
interface: ["Shikigami.Attestation.Resolve", "Shikigami.Behavior.Provider", "profileRequirement"]
tags: ["sanctioned-execution-profiles"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
requires: ["CAP-4"]
evidence:
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/ProfileResolutionSpec.hs"
    proves: "Active resolution and explicit unknown, expired, withdrawn, mutable, and ambiguous refusals."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs"
    proves: "Unknown profiles refuse before sessions; replay keeps the original content/digest; tuple mismatch refuses before dispatch."
  - kind: test
    resource: "shikigami-core/test/Shikigami/BehaviorProviderSpec.hs"
    proves: "Exact tuples constrain provider/model/options without fallback or silent translation."
---

# Sanctioned execution profile pinning

## Provides

A declaration can require a sanctioned execution profile. Resolution checks stored content against its digest and lifecycle before opening the run session. The resolved policy is journaled and applied to behavior and Flow provider calls; replay uses the originally recorded content rather than mutable live policy.

For [typed Flow decisions](typed-flow-decisions.md), the pinned profile restricts
the operator catalog and agent alias grants across the complete slot inventory.
Decision-only Flows can omit the unused process-default model check; Routing and
PracticeReview Flows retain it. Every actual decision call checks the final tuple.

## Adopt

Provision an immutable active profile in the migrated profile store and declare its identity/version requirement. Configure a provider and options that satisfy the exact policy tuple.

Builds on [CAP-4: Durable agent runs and Flows](durable-agent-flows.md).

## Evidence

- [ProfileResolutionSpec.hs](../../shikigami-core/test-postgres/Shikigami/ProfileResolutionSpec.hs): Active resolution and explicit unknown, expired, withdrawn, mutable, and ambiguous refusals.
- [AgentWorkflowSpec.hs](../../shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs): Unknown profiles refuse before sessions; replay keeps the original content/digest; tuple mismatch refuses before dispatch.
- [BehaviorProviderSpec.hs](../../shikigami-core/test/Shikigami/BehaviorProviderSpec.hs): Exact tuples constrain provider/model/options without fallback or silent translation.

## Limits

A profile declaration does not provision policy data. Resolution and dispatch constraints do not constitute a signed runtime attestation or proof of the actual served model. Profiles without a requested version still require an unambiguous match. Operational profile provisioning remains a deployment responsibility.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
