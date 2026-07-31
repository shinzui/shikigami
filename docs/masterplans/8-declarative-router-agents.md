---
id: 8
slug: declarative-router-agents
title: "Declarative router agents"
kind: master-plan
created_at: 2026-07-26T04:38:46Z
intention: "intention_01kyeb9j20e8prwv62v7mzp574"
---

# Declarative router agents

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

After this initiative, a Shikigami agent can declare that it is a router, expose a bounded
catalog of specialists from its existing `delegates` allow-list, and make one replay-safe,
typed route decision. An `architecture-practice-router` presented with an
OpenTelemetry-shaped payload can select `opentelemetry-practice-reviewer`, explain the
selection, and launch the specialist through the durable delegation mechanism planned in
`docs/plans/35-delegation-as-a-first-class-declared-capability.md`. A replay reuses the
recorded catalog and decision instead of consulting changed declarations or a model again.

The initiative includes additive Dhall and Haskell declaration types, candidate discovery,
lifecycle filtering, typed `matched` / `no-match` / `ambiguous` decisions, policy and
allow-list validation, durable delegation, and parent-session observability. Existing
non-router declarations remain valid. It excludes domain-specific review verdicts (owned by
`docs/masterplans/9-architecture-practice-review-flow.md`), global agent marketplaces,
repository watching, tool or sink authorization, source edits, and merge gating.


## Decomposition Strategy

The request spans three functional concerns that are independently demonstrable. EP-1 owns
the author-facing declaration language and compatibility proof. EP-2 turns those declarations
into a versioned, lifecycle-aware candidate catalog without running a model or spawning a
child. EP-3 owns the durable workflow boundary: typed decisions, journaling, validation,
delegation, and observability. This makes the schema reviewable before runtime work starts
and lets catalog behavior be tested as a pure boundary.

A single ExecPlan was rejected because it would mix Dhall evolution, directory policy, and
Keiro workflow semantics across more than five milestones. Splitting observability into a
fourth plan was also rejected because the routing decision and its audit record must be
written atomically under the same parent session; separating them would create an
unverifiable intermediate state.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Declare specialist expertise and router policy | docs/plans/40-declare-specialist-expertise-and-router-policy.md | cross-MP: plans 33 and 47 | None | Not Started |
| 2 | Resolve lifecycle-aware router candidate catalogs | docs/plans/41-resolve-lifecycle-aware-router-candidate-catalogs.md | EP-1; cross-MP: plans 33 and 47 | cross-MP: plan 23 | Not Started |
| 3 | Execute replay-safe typed routing and delegation | docs/plans/42-execute-replay-safe-typed-routing-and-delegation.md | EP-1, EP-2; cross-MP: plans 35 and 47 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 precedes both other children because it defines the `expertise` and `routing` fields
that candidate discovery reads and the validation rules that runtime code may assume. EP-2
then produces the resolved, versioned catalog consumed by EP-3. EP-3 therefore waits for
both EP-1 and EP-2.

There are also cross-MasterPlan prerequisites. EP-1 follows the additive schema pattern from
`docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md`. EP-3 must not
start until `docs/plans/35-delegation-as-a-first-class-declared-capability.md` has delivered
the declared allow-list, global budget, cycle checks, and Flow delegation capability; it
extends that mechanism rather than creating another. EP-2 consumes
`docs/plans/23-agent-lifecycle-control-with-meibo-principals.md` when available, but the
improvement request explicitly permits plan 33's local `enabled` field as an honest interim
source, making plan 23 a soft external dependency rather than a blocker. Plans 24 and 39 are
inherited through plan 35 for workflow evolution and checked topology.


## Integration Points

IP-1 — the canonical agent declaration. EP-1 owns additive `ExpertiseDecl` and
`RouterPolicy` shapes in `schema/Agent.dhall` and their mirrors in
`shikigami-api/src/Shikigami/Api/Agent.hs`. EP-2 and EP-3 only consume these shapes. The
fields use direct names under `DuplicateRecordFields`; no type-prefixed record fields are
introduced.

IP-2 — the candidate catalog. EP-2 owns `Shikigami.Router.Catalog`, including catalog
versioning, exclusion reasons, and lifecycle-source attribution. EP-3 journals the exact
catalog snapshot or its stable version plus complete entries before it evaluates a route.

IP-3 — the route decision. EP-3 owns `RouteDecision`, `RouteSelection`, `RouteOutcome`, and
their strict decoder/validator. A model-facing program may produce the JSON, but only the
validator may convert it into authority to delegate.

IP-4 — delegation governance. Existing plan 35 owns `delegates`, the durable tree-wide
budget, ancestor-cycle rejection, deterministic child workflow ids, and partial child
results. EP-3 calls that capability after routing checks; it does not spawn directly or
maintain a second budget.

IP-5 — lifecycle availability. Existing plan 23 owns the Meibo-backed `DirectoryHandle`
and lifecycle decisions. EP-2 adapts that source. Before plan 23 lands, it may report
`local-enabled` as the source and use plan 33's `enabled`; it must never label that result as
Meibo-verified.

IP-6 — routing observability. EP-2 defines exclusion data and EP-3 writes the catalog,
selection, rationale, confidence, declaration version, and failure class to the parent run
trace/session. Payload document bodies are excluded from logs.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1 M1: Add backward-compatible expertise and router-policy declaration types.
- [ ] EP-1 M2: Mirror and validate the types in Haskell and prove every existing manifest still loads.
- [ ] EP-1 M3: Add router and specialist proof manifests plus author documentation.
- [ ] EP-2 M1: Build a deterministic catalog from the router's declared delegates.
- [ ] EP-2 M2: Apply enabled/Meibo lifecycle availability with explicit exclusion reasons.
- [ ] EP-2 M3: Version, redact, and test the catalog boundary.
- [ ] EP-3 M1: Define and strictly decode the typed route decision.
- [ ] EP-3 M2: Journal catalog and decision under stable checked Keiro step names.
- [ ] EP-3 M3: Validate policy, lifecycle, allow-list, and budget before using plan 35 delegation.
- [ ] EP-3 M4: Record observability and prove matched, no-match, ambiguous, replay, and failure behavior.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Mori inspection confirmed that current `schema/Agent.dhall` has no identity, enablement,
  delegates, expertise, or routing fields yet; plans 33 and 35 are still unchecked. The new
  work must therefore target their documented future shapes and preserve the stated landing
  order rather than patching around them.
- The shipped `Shikigami.Agent.Delegate.delegate` already provides deterministic child ids and
  parent workflow/session lineage, but it accepts a raw child name and checks only depth.
  Plan 35 is the necessary governance layer; EP-3 must build on it.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Make plan 33 and plan 47 hard foundations for declaration/catalog work and make
  plan 35 a hard predecessor of routed execution.
  Rationale: the router extends the canonical agent schema and durable delegation machinery;
  recreating either would split validation, budget, lineage, and replay semantics.
  Date: 2026-07-30

- Decision: Use one MasterPlan with three child plans: declaration, catalog, and durable
  execution.
  Rationale: These are independently verifiable functional boundaries with a natural data
  flow, while a single plan would exceed the ExecPlan complexity threshold and mix unrelated
  schema, directory, and workflow risks.
  Date: 2026-07-25

- Decision: Treat plan 23 as a soft dependency of catalog construction and require honest
  source attribution when only local enablement is available.
  Rationale: The improvement request permits the interim, but explicitly forbids claiming a
  Meibo check that did not occur.
  Date: 2026-07-25

- Decision: Make the catalog snapshot and typed decision replay artifacts, not live lookups
  performed again on resume.
  Rationale: A router must not select a different specialist because declarations, lifecycle,
  or model output changed after the original workflow step.
  Date: 2026-07-25


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)


## Revision Notes

- 2026-07-30: Added the previously prose-only external edges to plans 33, 35, and 47 and
  kept plan 23 as a source-attributed soft dependency.
