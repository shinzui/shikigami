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

- [x] (2026-08-23T14:41:54Z) Refreshed this plan against governed Flow delegation, the
  checked language-5 workspace, the workflow evolution contract, current tracing ownership, and
  the repository's Keiro 0.14 cohort.
- [x] (2026-08-23T14:41:54Z) External prerequisites verified: plans 24, 35, 36, 39, and 47
  have landed. Plans 37 and 38 retain only unrelated migration-CLI configuration cleanup.
- [x] (2026-08-23T19:00:21Z) Reconciled durable routing with the imminent first release:
  direct static route labels become the reported v1 baseline under ADR 0027, with no router
  patch id or legacy branch for an empty pre-release population.
- [x] (2026-08-23T19:44:44Z) Prerequisites: child plans 40 and 41 have landed.
- [x] (2026-08-23T19:52:47Z) M1: Defined typed route outcomes/selections, strict JSON
  decoding, and catalog/policy validation; all six focused decision tests pass.
- [ ] M2: add static hyphenated catalog and decision operations directly to the clean v1 workflow baseline, with no router patch or legacy branch.
- [ ] M2: implement a replay-safe Routing Flow capability, a production evaluator seam, and a deterministic test evaluator.
- [ ] M3: preflight every selection, atomically reserve the complete plan-35 batch, and delegate only through plan 35.
- [ ] M3: preserve matched child results and operational failures without semantic coercion.
- [ ] M4: add bounded routing telemetry and real-Postgres replay/authorization tests.
- [ ] Final: checked DSL, domain harness, `cabal test all`, and replay proof are green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Plan 35 has landed. `Shikigami.Agent.Delegate.delegate` now checks the declaration allow-list,
  complete ancestor lineage, depth, and durable tree-wide budget before spawning, and the Flow
  `Delegate` effect calls the same function.
- `Shikigami.Store.DelegationBudget` exposes only `reserveDelegationSlot`, so the anticipated
  multi-selection gap is real. Sequential calls can reserve and spawn an early child before a
  later selection discovers budget exhaustion.
- The July step spellings `route-catalog:<label>` and `route-decision:<label>` contain `:` and
  cannot appear in a declared Keiro workflow body. The checked specification accepts static
  wire words. Keiro deliberately classifies their direct addition as `WorkflowBodyChanged`;
  ADR-0027 permits that reported break only for the initial v1 baseline while there are no
  users, durable values, or external consumers.
- `FlowRuntime` now carries only acknowledgement configuration. Flow effects are installed as
  interpreters in `runFlowBehavior`; a routing environment belongs in a `Routing` interpreter,
  not in `FlowRuntime`.
- `Shikigami.Telemetry` now lives in `shikigami-workers` and constructs worker tracers. Domain
  spans and attributes are emitted in `Shikigami.Agent.Workflow` through Shibuya's tracing
  effect.
- The delivered capability resolver rejects a declaration that combines non-empty
  `capabilityOverlays` with non-empty `delegates`. A router therefore evaluates with the active
  model/provider environment and no overlay tools; changing that authority boundary is outside
  this initiative.


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

- Decision: Use static hyphenated step names for each registered routing call site and place
  the complete catalog/decision addition inside one new `shikigami-routing-steps-v1` patch.
  Status: Superseded on 2026-08-23 by the clean-v1 baseline decision below.
  Rationale: colon-bearing or runtime-computed labels cannot be checked as workflow wire words;
  static names keep the durable inventory visible to `just keiro-gate`.
  Date: 2026-08-23

- Decision: The patch's legacy branch fails a routing call as unavailable without resolving a
  catalog, evaluating a model, reserving budget, or spawning a child.
  Status: Superseded on 2026-08-23 by the clean-v1 baseline decision below.
  Rationale: a pre-patch in-flight run must retain the old body shape. There was no routing
  capability in that shape, so performing new routing work on the false branch would defeat the
  patch.
  Date: 2026-08-23

- Decision: Add the static route catalog and decision labels directly to the first released
  workflow body, without a router patch id or false branch.
  Rationale: Shikigami has no users, resumable journals, queued/stored old payloads, or external
  wire consumers, and v1 is imminent. A router patch would protect an empty population and ship
  dead code in the first release. The direct change remains declared, generated, replay-tested,
  and reported as the expected pre-v1 `WorkflowBodyChanged` under ADR 0027; after v1, ADR 0012
  applies without this exception.
  Date: 2026-08-23

- Decision: Add atomic `reserveDelegationSlots` beside plan 35's single-slot operation, then
  reuse the existing governed `delegate` function for child creation.
  Rationale: one locked transaction can accept the whole idempotent batch or none of its new
  reservations, while repeated `delegate` calls observe those ids as already reserved and keep
  one policy/spawn boundary.
  Date: 2026-08-23

- Decision: Install routing as its own Flow effect interpreter and inject the evaluator through
  run dependencies; production uses the active model/provider policy while tests use a
  deterministic evaluator.
  Rationale: `FlowRuntime` is acknowledgement configuration, and a hard-coded stub would prove
  replay without delivering a replaceable production routing seam.
  Date: 2026-08-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

`shikigami-core/src/Shikigami/Agent/Workflow.hs` runs durable agent workflows with named
Keiro steps. Flow behaviors are looked up in `shikigami-core/src/Shikigami/Flow.hs` and their
effects are interpreted by `runFlowBehavior`. `Shikigami.Flow.FlowEffects` currently contains
Workflow, Memory, Sink, Activity, Acknowledgement, and Delegate. Memory, Sink, Acknowledgement,
and Delegate are replay-safe capabilities; routing becomes another capability rather than
restoring ambient `IOE` or `Store` to Flow bodies. This follows
`docs/adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md`.

The delivered primitive in `shikigami-core/src/Shikigami/Agent/Delegate.hs` creates deterministic
child workflow ids from parent id, target, and stable key; checks allow-list, cycle, and depth;
reserves the root-wide budget; spawns the child; records its `ingest-job`; and awaits a typed
result. `shikigami-core/src/Shikigami/Flow/Delegate.hs` exposes the same machinery to Flow.
`docs/adr/0023-delegation-is-governed-at-the-child-spawn-boundary.md` requires every caller to
keep using that path. This plan extends the same budget store with atomic batch reservation but
does not create another ledger or child-registration implementation.

`domain/shikigami.keiro-workspace` composes language-5 agent-run and conversation members. The
repository is pinned to Keiro/keiro-dsl 0.14. `docs/workflow-versioning.md` and
`docs/adr/0027-the-first-release-establishes-one-clean-durable-baseline.md` permit this one
pre-release body reset because no durable population exists. The direct labels are still checked,
generated, and honored by runtime code. `keiro-diff` must report the deliberate
`WorkflowBodyChanged`, while `keiro-check`, `keiro-inspect`, deterministic scaffolding, generated
conformance, replay tests, and the full suite must pass. After v1,
`docs/adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md` again requires every
declared addition to use a real patch branch.

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

Milestone 2 updates `domain/shikigami-agent-run.keiro` through its workspace. Add the static
labels used by the first registered router directly to the v1 body:
`route-catalog-architecture-practice` and `route-decision-architecture-practice`. Regenerate
the checked modules and conformance expectations without changing the declared patch set. The
runtime always installs the Routing interpreter; do not add a `PatchId`, a legacy-unavailable
error, or a false branch for nonexistent pre-v1 runs. Do not use colon labels and do not derive
step names from payload data. Before committing, re-confirm that no release/deployment or durable
population has appeared, run every non-diff gate component, and capture the expected direct-body
`WorkflowBodyChanged` report against the pre-reset revision.

Create `shikigami-core/src/Shikigami/Flow/Routing.hs` beside `Flow/Delegate.hs`. Add `Routing`
to `FlowEffects`. `route` takes a validated static `RouteLabel`; `runRouting` maps that label to
the two declared `StepName`s, resolves and journals the complete catalog in the first step,
calls `RouteEvaluator` and journals its raw versioned JSON in the second, then strictly decodes
and validates it. Replays return both recorded values before the resolver or evaluator runs.
Install the interpreter in `runFlowBehavior` beside `runDelegate`. Extend that function's inputs
only as needed to pass the active `BehaviorEnv` and per-process `RoutingRuntime`; do not put
these in the acknowledgement-only `FlowRuntime`. Add
`RoutingRuntime` to `AgentRunDeps`. Its catalog-resolver closure captures the same
`AgentLoadReport`, `DirectoryHandle`, and validated lifecycle source kind produced at worker
startup; invocation inside the catalog step reads exactly one immutable snapshot and calls
EP-2's pure builder. Its evaluator field is the injected production/test seam.

Tests use a deterministic evaluator. The production `RouteEvaluator` is an explicit dependency
that uses the process's active behavior/provider policy and returns raw JSON; it is not a second
hard-coded stub hidden in the interpreter. If the router declares a sanctioned profile, extend
the existing profile-constraining branch so its model call uses that constrained environment.
Do not enable capability overlays for routers: the delivered resolver deliberately rejects
overlays combined with delegates. Model/provider failure remains an operational routing error.

Milestone 3 maps a validated matched decision to plan 35. Add pure batch preflight in
`Shikigami.Agent.Delegate`: validate every target against the journaled declaration allow-list,
the recorded catalog availability, distinct stable keys, the complete ancestor lineage, depth,
and `maxSelections`; compute every deterministic child workflow id before touching the store.
Add `reserveDelegationSlots` to `Shikigami.Store.DelegationBudget`. Under one ledger-row lock it
recognizes already-reserved ids, verifies the complete new count fits, inserts every new
reservation, and increments consumption once by that count; otherwise it writes nothing. Then
call the existing Flow delegation capability for each target. Its single-slot reservation sees
the ids as already reserved, and its existing checks remain the final spawn boundary. Await
results in selection order. No-match and ambiguous return typed parent results without invoking
delegation. Preserve routing, delegation, evaluator, and child failures as failures; do not
manufacture a semantic outcome.

Milestone 4 adds bounded spans/attributes through the tracing effect already used by
`Shikigami.Agent.Workflow` and real-Postgres workflow tests in `shikigami-core-test`. Trace
fields include parent session/workflow, catalog
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
sed -n '1,220p' docs/workflow-versioning.md
sed -n '1,230p' shikigami-core/src/Shikigami/Agent/Delegate.hs
sed -n '1,180p' shikigami-core/src/Shikigami/Flow/Delegate.hs
sed -n '680,740p' shikigami-core/src/Shikigami/Agent/Workflow.hs
```

Check the complete durable topology and generated layer before compiling runtime changes. The
first four commands must pass. The final diff command must exit non-zero only because the direct
pre-v1 body growth is reported as `WorkflowBodyChanged`; record its report in this plan:

```bash
nix develop -c just keiro-check
nix develop -c just keiro-inspect
nix develop -c just keiro-scaffold
nix develop -c cabal test keiro-shikigami-conformance
nix develop -c just keiro-diff <pre-v1-baseline-ref>
```

Format and validate the implementation:

```bash
nix develop -c fourmolu -i shikigami-core/src/Shikigami/Router/Decision.hs
nix develop -c fourmolu -i shikigami-core/src/Shikigami/Flow/Routing.hs
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

No-match and ambiguous responses return their typed outcomes and spawn zero children. A matched
response may spawn multiple distinct children but never beyond `maxSelections` or available
global budget. A batch with two new children and only one remaining slot writes no reservation
and spawns no child. Replaying a successfully reserved batch spends no additional slots. A
runtime/evaluator/decoder/child failure remains an error. Replaying the same workflow after
replacing the evaluator and lifecycle snapshot must return the original decision and child ids
and create no duplicate child. There is no pre-patch routing scenario to preserve: every v1 run
uses the same routing body because no pre-router durable population exists. Existing non-router
flows continue to run. The declared patch set contains
no `shikigami-routing-steps-v1` id. All non-diff gate components and
`nix develop -c cabal test all` exit zero; `keiro-diff` against the pre-v1 baseline exits non-zero
with the single expected direct-body `WorkflowBodyChanged` finding, which is captured in Progress
and accepted under ADR 0027. A diff against the resulting v1 baseline is green.


## Idempotence and Recovery

Both new workflow operations are static declared labels in the clean v1 baseline. There is no
router patch record or false branch. A crash before a step is recorded re-executes the operation;
catalog and decision values are deterministic for
their inputs. Batch budget reservation is keyed by deterministic child workflow ids, so retrying
cannot spend twice. A crash after reservation but before one or more child registrations leaves
safe reserved slots; replay calls the same governed `delegate` operations and repairs the same
child ids. Tests and gate commands are safe to repeat. Generated Keiro modules are regenerated
by the gate and are not formatted manually.


## Portfolio Reconciliation (2026-08-23)

Plans 24, 35, 36, 39, and 47 are complete; plans 37 and 38 have delivered every surface used
here, and their remaining migration-CLI cleanup is unrelated. This plan now waits only on child
plans 40 and 41. Target the checked language-5 workspace and the repository's Keiro 0.14 cohort,
establish the direct routing labels as the reported pre-v1 baseline under ADR 0027, and reuse plan 35's allow-list, global budget, cycle,
typed delegation, and child-operation paths.


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

data RoutingRuntime = RoutingRuntime
  { resolveCatalog
      :: ValidatedRouterDeclaration
      -> IO CandidateCatalog
  , evaluateRoute
      :: BehaviorEnv
      -> CandidateCatalog
      -> Value
      -> IO (Either RoutingFailure Value)
  }

reserveDelegationSlots
  :: (Store :> es)
  => DelegationBudgetId
  -> Maybe (WorkflowId, DelegationBudget)
  -> NonEmpty WorkflowId
  -> UTCTime
  -> Eff es (Either BudgetReservationError BatchReservationResult)
```

`RouteLabel` is a validated enum/newtype whose initial value maps to the static suffix
`architecture-practice`; arbitrary text is rejected before a step name is formed. If `Natural`
version fields are bounded into a newtype during decoding, keep the wire value `1` for the
initial schema. Direct field names and strict records follow the repository record pattern.
Dependencies are
`docs/plans/40-declare-specialist-expertise-and-router-policy.md`,
`docs/plans/41-resolve-lifecycle-aware-router-candidate-catalogs.md`, Keiro/Effectful APIs
already in this repository,
`docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md` and
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` for workflow
evolution, and `docs/plans/35-delegation-as-a-first-class-declared-capability.md` for all delegation governance and child
operations. Use the Keiro source located by `mori registry show shinzui/keiro --full`; do not
guess at a changed workflow API.


## Revision Notes

- 2026-08-23: Refreshed the plan after governed delegation and the checked workflow system
  landed. Replaced impossible colon labels with static hyphenated labels under a real patch,
  specified atomic batch reservation over the existing ledger, moved routing into its own Flow
  interpreter, corrected tracing/test/gate ownership, and updated the target from Keiro 0.4 to
  the repository's 0.14 cohort.
- 2026-08-23: Reconciled the workflow shape with the imminent first release and the confirmed
  absence of users or durable state. Superseded the router patch and legacy-unavailable branch,
  made the static labels part of the direct v1 baseline, and replaced the impossible passing
  pre-reset diff criterion with explicit component checks plus a captured expected
  `WorkflowBodyChanged` report under ADR 0027.
