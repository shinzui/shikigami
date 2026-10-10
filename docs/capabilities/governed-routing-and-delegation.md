---
type: "Capability"
title: "Governed routing and delegation"
description: "Validate routing decisions and run bounded durable child agents with deterministic identities and retained lineage."
capabilityId: "CAP-8"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-workers", "shikigami-migrations"]
interface: ["Shikigami.Flow.Routing", "Shikigami.Flow.Delegate", "Shikigami.Agent.Delegate", "routerPolicy", "delegateTargets"]
tags: ["governed-routing-and-delegation"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
requires: ["CAP-4"]
evidence:
  - kind: test
    resource: "shikigami-core/test/Shikigami/RouterDecisionSpec.hs"
    proves: "Catalog freshness, declared expertise, confidence, duplicate selections, and fan-out validation."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/RouterWorkflowSpec.hs"
    proves: "Journaled matched/no-match/ambiguous outcomes, replay, exhausted budgets, and child failures."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs"
    proves: "Parent suspension/resume, cycle refusal, root budget, lineage, and sibling cancellation."
---

# Governed routing and delegation

## Provides

A Flow can journal a specialist catalog and model routing proposal, validate it against declaration policy, and delegate executable selections. Child workflow identities are deterministic and reservation state bounds depth and root work. Parents can wait for individual or multiple children, retain successful results beside failures, and explicitly cancel siblings.

## Adopt

Declare expertise, `routerPolicy`, `delegateTargets`, and delegation budgets, then use the compiled routing/delegation Flow capabilities. The proof supervisor and architecture-practice router demonstrate the path.

Builds on [CAP-4: Durable agent runs and Flows](durable-agent-flows.md).

## Evidence

- [RouterDecisionSpec.hs](../../shikigami-core/test/Shikigami/RouterDecisionSpec.hs): Catalog freshness, declared expertise, confidence, duplicate selections, and fan-out validation.
- [RouterWorkflowSpec.hs](../../shikigami-core/test-postgres/Shikigami/RouterWorkflowSpec.hs): Journaled matched/no-match/ambiguous outcomes, replay, exhausted budgets, and child failures.
- [AgentWorkflowSpec.hs](../../shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs): Parent suspension/resume, cycle refusal, root budget, lineage, and sibling cancellation.

## Limits

No-match and ambiguous outcomes spawn no children. This is delegation within the configured runtime and catalog; authenticated cross-runtime A2A interoperability is not implemented. The proof researchers produce fixed findings, so their example fan-out proves orchestration rather than research quality.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
