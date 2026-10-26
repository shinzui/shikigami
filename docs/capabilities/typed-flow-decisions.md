---
type: "Capability"
title: "Governed typed decisions in durable Flows"
description: "Pin typed programs and admitted model aliases, journal validated outcomes, and retain actual-attempt evidence across retries and restart."
capabilityId: "CAP-21"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core","shikigami-workers","shikigami-migrations"]
interface: ["Shikigami.Flow.Decision.decide","Shikigami.Program.Decision","Shikigami.Decision.ModelCatalog","Shikigami.Decision.Evidence"]
tags: ["typed-flow-decisions"]
generated:
  by: "process:shikigami-documentation-refresh"
  at: "2026-10-25T00:00:00Z"
requires: ["CAP-4"]
evidence:
  - kind: module
    resource: "shikigami-core/src/Shikigami/Flow/Decision.hs"
    proves: "Closed slot labels, pinned policy preparation, retained result decoding, and the replay-safe decision interpreter."
  - kind: test
    resource: "shikigami-core/test/Shikigami/DecisionRunnerSpec.hs"
    proves: "Actual Predict calls cross per-attempt hooks, exact model/profile checks, output validation, and evidence-failure boundaries."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/DecisionWorkflowSpec.hs"
    proves: "Mixed models, historical result replay without calls, pending pins, lost appends, old patch snapshots, and governed delegation."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/DecisionEvidenceSpec.hs"
    proves: "Durable attempt and compliance accounting across connections, retries, unresolved calls, and persistence faults."
---

# Governed typed decisions in durable Flows

## Provides

A compiled Flow invokes a registered typed Shikumi program at a declared slot, selects an operator-admitted alias, validates its result, and branches through governed capabilities. Admission intersects the operator catalog, agent `decisionModels`, slot inventory, and pinned profile before the first decision. Immutable program state and model descriptors are journaled; committed results retain their historical codec independently of executable programs.

Each actual provider attempt records an expectation before dispatch and terminal evidence/compliance facts before a successful result append. The public evidence API provides `readDecisionReport`, `listDecisionCalls`, and finalization over PostgreSQL.

## Adopt

Follow [Typed decisions in Flows](../user/typed-decisions.md) for the deterministic two-model example, and the [authoring guide](../shikumi-flow-decisions.md) to register programs, immutable bindings, validators, result codecs, and static slots. Configure `behavior.decisionModels`, grant aliases in the agent declaration, migrate the database, and run the workflow worker. Retain exact historical bindings for pending work and pure codecs for completed work.

Builds on [CAP-4: Durable agent runs and Flows](durable-agent-flows.md).

## Evidence

- [Decision.hs](../../shikigami-core/src/Shikigami/Flow/Decision.hs): Closed slot labels, pinned policy preparation, retained result decoding, and the replay-safe decision interpreter.
- [DecisionRunnerSpec.hs](../../shikigami-core/test/Shikigami/DecisionRunnerSpec.hs): Actual Predict calls cross per-attempt hooks, exact model/profile checks, output validation, and evidence-failure boundaries.
- [DecisionWorkflowSpec.hs](../../shikigami-core/test-postgres/Shikigami/DecisionWorkflowSpec.hs): Mixed models, historical result replay without calls, pending pins, lost appends, old patch snapshots, and governed delegation.
- [DecisionEvidenceSpec.hs](../../shikigami-core/test-postgres/Shikigami/DecisionEvidenceSpec.hs): Durable attempt and compliance accounting across connections, retries, unresolved calls, and persistence faults.

## Limits

The current registered example has triage and investigation slots; adding labels or changing durable bodies requires the workflow versioning gate. Each slot runs once per generation. Pending missing pins refuse without fallback. A crash after dispatch but before result append can repeat a provider call; completed result replay makes no new calls. Unknown usage and unresolved attempts remain uncertain. Reports are unsigned and library-only, bounded to 10,000 attempts with detail pages of at most 200. Live HTTP execution was not part of the recorded deterministic acceptance proof. This does not implement intermediate Skill-turn recovery, whole-assignment selection, or adaptive workers.

This provision is experimental and unreleased; its implementation does not establish a released compatibility promise.

