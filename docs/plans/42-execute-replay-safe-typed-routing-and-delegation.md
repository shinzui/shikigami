---
id: 42
slug: execute-replay-safe-typed-routing-and-delegation
title: "Execute replay-safe typed routing and delegation"
kind: exec-plan
created_at: 2026-07-26T04:38:46Z
intention: "intention_01kyeb9j20e8prwv62v7mzp574"
master_plan: "docs/masterplans/8-declarative-router-agents.md"
---

# Execute replay-safe typed routing and delegation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A Flow router can resolve its declared specialist catalog, obtain a typed semantic decision,
validate the entire decision, and delegate through plan 35's governed child-run capability.
`matched` may select one or more available specialists within both policy and durable budget;
`no-match` and `ambiguous` are successful semantic outcomes that spawn no child. A classifier
error, invalid decision, unavailable target, exhausted budget, or child failure is an
operational failure and is never rewritten as a semantic outcome.

The proof runs `architecture-practice-router` twice with the same workflow id. The first run
records a catalog and selects `opentelemetry-practice-reviewer`; the replay reuses that exact
catalog, decision, and child workflow id even if declarations or evaluator output have since
changed. Parent-session traces show bounded candidate names, selection, expertise,
confidence, rationale, versions, and exclusions without logging document bodies.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Prerequisites: `docs/plans/40-declare-specialist-expertise-and-router-policy.md`, `docs/plans/41-resolve-lifecycle-aware-router-candidate-catalogs.md`, `docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md`, `docs/plans/35-delegation-as-a-first-class-declared-capability.md`, and `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md` through `docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` have landed.
- [ ] M1: define typed route outcomes/selections, strict JSON decoding, and policy validation.
- [ ] M2: add catalog and decision operations to the checked Keiro specification with stable labels.
- [ ] M2: implement a replay-safe Routing Flow capability and a stub evaluator.
- [ ] M3: preflight every selection, reserve plan-35 budget, and delegate only through plan 35.
- [ ] M3: preserve matched child results and operational failures without semantic coercion.
- [ ] M4: add bounded routing telemetry and real-Postgres replay/authorization tests.
- [ ] Final: checked DSL, domain harness, `cabal test all`, and replay proof are green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The shipped `delegate` accepts a raw child name and checks depth only. Plan 35 must land
  first so this plan can rely on its allow-list, ancestor cycle check, and durable global
  budget instead of duplicating them.
- Multiple selections require batch preflight before the first spawn. If plan 35 lands with
  only one-at-a-time reservation, its owned module needs a batch reservation operation over
  the same ledger before routed fan-out can be implemented safely.


## Decision Log

Record every decision made while working on the plan.

- Decision: Model `matched`, `no-match`, and `ambiguous` as a closed algebraic data type, not
  a record with loosely related optional fields.
  Rationale: The decoder can then reject impossible states such as `no-match` with executable
  selections or `matched` with an empty list.
  Date: 2026-07-25

- Decision: Journal catalog resolution and route evaluation as two labeled steps, then
  validate/delegate from those recorded values.
  Rationale: Replaying either live lookup could change the candidate universe or semantic
  decision after the original run.
  Date: 2026-07-25

- Decision: Preflight and reserve a routed batch through plan 35 before spawning any child.
  Rationale: Sequential validation can spawn an early child before discovering that a later
  selection violates the budget, contradicting the request's all-targets-before-spawn rule.
  Date: 2026-07-25


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

`shikigami-core/src/Shikigami/Agent/Workflow.hs` runs durable agent workflows with named
Keiro steps. Flow behaviors are looked up in `shikigami-core/src/Shikigami/Flow.hs` and their
effects are interpreted by `runFlowBehavior`. `shikigami-core/src/Shikigami/Flow/Capability.hs`
currently contains Activity, Memory, and Sink effects. Plan 25 makes Memory labeled and
replay-safe; plan 35 adds governed Flow delegation.

The shipped imperative primitive in `shikigami-core/src/Shikigami/Agent/Delegate.hs` creates
deterministic child workflow ids, records the child's `ingest-job`, and awaits a typed result.
Plan 35 owns the future allow-list, tree-wide budget, cycle prevention, partial collection,
and cancellation semantics. This plan may add a batch entry point in the same plan-35-owned
module if required, but must not create another ledger or spawn path.

`docs/plans/41-resolve-lifecycle-aware-router-candidate-catalogs.md` creates
`CandidateCatalog`, including unavailable entries and a stable version. A route
evaluator is a replaceable function that receives the original trigger payload plus that
catalog and returns JSON. Only strict decoding and validation turn the JSON into a
`RouteDecision`; model output alone is never authority.


## Plan of Work

Milestone 1 adds `Shikigami.Router.Decision` in the plan-36 core package. Define a closed
`RouteDecision`, `RouteSelection`, and `RoutingError`. Use the confidence enum from
`docs/plans/40-declare-specialist-expertise-and-router-policy.md`.
Decode a versioned wire value and then validate it against the exact `CandidateCatalog` and
`RouterPolicy`: matched selections are non-empty and distinct; every name is declared and
available; expertise keys are a subset of that candidate's declaration; confidence meets
the minimum; selection count is within `maxSelections`; no-match has no executable choices;
ambiguous alternatives are advisory and spawn nothing. Reject undeclared, unavailable, low
confidence, duplicate, oversized, and stale-catalog decisions with distinct errors.

Milestone 2 updates the `domain/shikigami.keiro-workspace` artifact owned by
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` with additive, stable workflow steps
`route-catalog:<label>` and `route-decision:<label>` and passes parse, check, scaffold,
harness, and evolution diff. Add a `Routing` effect to
`shikigami-core/src/Shikigami/Flow/Capability.hs` (or its plan-36 destination). Its caller
supplies a non-empty `RouteLabel`; `runRouting` resolves the catalog from
`docs/plans/41-resolve-lifecycle-aware-router-candidate-catalogs.md` inside the first
Keiro step and calls `RouteEvaluator` inside the second. Replays return recorded JSON before
the resolver or evaluator executes. Thread `RoutingEnv` through `FlowRuntime` and
`runFlowBehavior`. Tests count resolver/evaluator invocations and prove both remain one after
replay.

Milestone 3 maps a validated matched decision to plan 35. Before spawning, call its batch
preflight/reservation with every selected agent and the deterministic child ids that will be
used. The operation checks allow-list, current recorded-catalog availability, ancestor
cycles, maximum selections, and remaining global budget atomically/idempotently. Then call
the existing Flow delegation capability and await results in selection order. No-match and
ambiguous return typed parent results without invoking delegation. Preserve `RouterFailure`,
`DelegationError`, and child failures as failures; do not manufacture a verdict.

Milestone 4 adds telemetry in `Shikigami.Telemetry` and real-Postgres workflow tests in the
plan-36 integration test package. Trace fields include parent session/workflow, catalog
version/source, bounded candidate and excluded names, selected names, expertise keys,
confidence, rationale capped to a documented length, and error category. Do not record the
full trigger, candidate descriptions, changed documents, or model prompt. Tests cover
matched single/multi, no-match, ambiguous, undeclared name, paused name, low confidence,
fan-out limit, exhausted budget, replay after declaration/evaluator changes, and child
failure.
Put pure decode/validation cases in
`shikigami-core/test/Shikigami/RouterDecisionSpec.hs` and durable real-Postgres cases in
`shikigami-core/test/Shikigami/RouterWorkflowSpec.hs` (or their exact plan-36 package
destinations), and register both modules in the final core test component.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`.

```bash
sed -n '1,260p' docs/plans/35-delegation-as-a-first-class-declared-capability.md
sed -n '1,240p' docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md
sed -n '277,380p' shikigami-core/src/Shikigami/Agent/Workflow.hs
sed -n '1,260p' shikigami-core/src/Shikigami/Flow/Capability.hs
```

Check the durable topology before compiling runtime changes:

```bash
nix develop -c cabal run keiro-dsl -- parse domain/shikigami.keiro-workspace
nix develop -c cabal run keiro-dsl -- check domain/shikigami.keiro-workspace --emit
nix develop -c cabal run keiro-dsl -- diff domain/shikigami.keiro-workspace --since HEAD^
```

Format and validate the implementation:

```bash
nix develop -c fourmolu -i shikigami-core/src/Shikigami/Router/Decision.hs
nix develop -c cabal test shikigami-core:shikigami-core-domain
nix develop -c cabal test shikigami-core-test --test-options='-p "router"' --test-show-details=direct
nix develop -c cabal test all
```

The focused replay test must show one resolver call, one evaluator call, one child workflow,
and the same catalog/decision/child ids across the initial run and replay.


## Validation and Acceptance

Using the proof declarations from
`docs/plans/40-declare-specialist-expertise-and-router-policy.md` and stub source from
`docs/plans/41-resolve-lifecycle-aware-router-candidate-catalogs.md`, an OpenTelemetry payload must produce
`Matched` with `opentelemetry-practice-reviewer`; the child must carry parent session,
parent workflow, depth, and global budget lineage. A classifier response naming an
undeclared agent is rejected before a budget reservation or child journal exists. A paused
candidate is likewise rejected with its catalog exclusion reason.

No-match and ambiguous responses return their typed outcomes and spawn zero children. A
cross-domain matched response may spawn multiple distinct children but never beyond
`maxSelections` or available global budget. A runtime/evaluator/decoder/child failure remains
an error. Replaying the same workflow after replacing the evaluator and lifecycle snapshot
must return the original decision and child ids and create no duplicate child. Existing
non-router flows continue to run. The Keiro checks and `nix develop -c cabal test all` exit
zero.


## Idempotence and Recovery

Both new workflow operations are additive labeled steps and use the checked evolution gate.
Plan 24's final compatibility rules govern any already-running Flow. A crash before a step is
recorded re-executes the operation; catalog and decision values are deterministic for their
inputs. Batch budget reservation is keyed by deterministic child workflow ids, so retrying
cannot spend twice. A crash after some child spawns finds the same child ids through Keiro
instead of creating new workflows. Tests and DSL commands are safe to repeat.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 35, 40, 41, and 47; plans 24 and 39 are inherited through
plan 35. Journal the exact candidate catalog and routing decision under Keiro 0.4 checked topology,
and reuse plan 35's allow-list, global budget, cycle, and typed delegation paths.


## Interfaces and Dependencies

The public domain and capability surface is:

```haskell
data RouteSelection = RouteSelection
  { agent :: !Text
  , expertise :: ![Text]
  , confidence :: !RouterConfidence
  , rationale :: !Text
  }

data RouteDecision
  = Matched { version :: !Natural, catalogVersion :: !CatalogVersion, selections :: !(NonEmpty RouteSelection) }
  | NoMatch { version :: !Natural, catalogVersion :: !CatalogVersion, rationale :: !Text }
  | Ambiguous { version :: !Natural, catalogVersion :: !CatalogVersion, alternatives :: !(NonEmpty RouteSelection), rationale :: !Text }

newtype RouteLabel = RouteLabel { value :: Text }

route
  :: (Routing :> es)
  => RouteLabel
  -> Value
  -> Eff es RouteDecision

validateRouteDecision
  :: RouterPolicy
  -> CandidateCatalog
  -> RouteDecision
  -> Either (NonEmpty RoutingError) ValidatedRouteDecision
```

If `Natural` version fields are bounded into a newtype during decoding, keep the wire value
`1` for the initial schema. Direct field names and strict records follow the repository record
pattern. Dependencies are
`docs/plans/40-declare-specialist-expertise-and-router-policy.md`,
`docs/plans/41-resolve-lifecycle-aware-router-candidate-catalogs.md`, Keiro/Effectful APIs
already in this repository,
`docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md` and
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` for workflow
evolution, and `docs/plans/35-delegation-as-a-first-class-declared-capability.md` for all delegation governance and child
operations. Use the Keiro source located by `mori registry show shinzui/keiro --full`; do not
guess at a changed workflow API.
