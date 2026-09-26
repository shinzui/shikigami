---
id: 76
slug: compose-and-verify-typed-shikumi-decisions-in-durable-flows
title: "Compose and verify typed Shikumi decisions in durable Flows"
kind: exec-plan
created_at: 2026-09-26T18:34:42Z
intention: "intention_01m3fft4cceb1ba9t3fammx5x4"
master_plan: "docs/masterplans/13-compose-shikumi-decisions-in-durable-flows.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T18:34:42Z
---

# Compose and verify typed Shikumi decisions in durable Flows


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Let a registered durable Flow triage with one authorized Shikumi program/model, branch on its typed result, and investigate with another before returning or delegating. Restart the same workflow after changing the process default, provider responses, catalog and available program implementations: completed decisions keep their original results and make no new calls. A pending decision uses its pinned contract or fails clearly if that exact implementation/binding is unavailable.

Hard dependencies are `docs/plans/73-define-typed-decision-programs-and-authorized-model-catalogs.md`, `docs/plans/74-run-shikumi-decisions-through-governed-provider-calls.md`, and `docs/plans/75-persist-decision-call-evidence-across-retries-and-restarts.md`. They supply the typed registry and operator catalog, governed runner, and restartable evidence store. This plan wires those concrete artifacts into the agent-run workflow, provides the example, and proves all six acceptance cases in [IR-12](../improvement-requests/compose-shikumi-decisions-in-durable-flows.md).


## Progress


Implementation has not started. Seed unchecked milestone entries when implementation begins.


## Surprises & Discoveries


None recorded during implementation.


## Decision Log


2026-09-26: Pin every declared decision slot and allowed model descriptor before any decision runs. The second step must not adopt a newly deployed catalog simply because it has not executed yet.

2026-09-26: Use static slot constructors and literal checked labels for policy, preparation and result steps. A counter, arbitrary payload label, or colon workaround would put decision identity outside the evolution gate.

2026-09-26: Preserve old workflow behavior behind a real patch false branch. Do not assume the historical pre-v1 empty-state exception remains available at implementation time.

2026-09-26: The example uses two finite decisions and the existing governed Delegate/Sink capabilities. It requires no unbounded loop or journal rotation; future looping authors must follow the continueAsNew rules.


## Outcomes & Retrospective


To be filled during implementation. Completion includes executable acceptance evidence, authoring documentation, and distillation of durable decisions from all four plans into local ADRs.


## Context and Orientation


`shikigami-core/src/Shikigami/Flow.hs` defines `FlowDef`, `flowRegistry`, `registeredFlowNames`, and `FlowEffects`. The latter permits Workflow plus explicit capabilities and deliberately excludes IOE and Store. `shikigami-core/src/Shikigami/Flow/Routing.hs` demonstrates a closed `RouteLabel` mapped to literal catalog and decision journal names, but it only evaluates one dedicated router prompt with the active model. `Shikigami.Router.Catalog`, `Router.Decision`, and `Flow.Delegate` own catalog snapshots, strict route validation, and governed delegation.

`shikigami-core/src/Shikigami/Agent/Workflow.hs` journals `lookup-agent` and `resolve-profile`, then constrains the process default `BehaviorEnv` for all Flow behaviors in `behaviorEnvForProfile`. The constrained environment flows into `runFlowBehavior`, which composes the capability interpreters. That function currently translates only an approval exception into a bounded Flow failure; decision exceptions must receive an explicit classification rather than escaping arbitrarily. Profile data must be threaded through the run/session functions to the new capability; passing only the selected default environment loses the authority needed to choose a second model.

The worker constructor is `shikigami-workers/src/Shikigami/Workers/Command/Worker.hs`; one-off durable execution is `shikigami-agent/src/Shikigami/Agent/Command/AgentRun.hs`. Audit the central runtime/bootstrap owner used by both and the resume dependencies before wiring: resumed workflows must use the same catalog, runner, evidence and options construction path. `shikigami-core/src/Shikigami/Workflow/Versioning.hs` is the only workflow-options owner. Checked labels live in `domain/shikigami-agent-run.keiro`; generated hand-owned assertions are in `shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/KeiroConformance/Expectations.hs`.

Relevant decisions are [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md), [ADR 0004](../adr/0004-one-options-value-and-a-checked-patch-set.md), [ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md), [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md), [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md), [ADR 0023](../adr/0023-delegation-is-governed-at-the-child-spawn-boundary.md), [ADR 0028](../adr/0028-a-router-catalog-is-a-bounded-snapshot-of-declared-authority.md), and [ADR 0029](../adr/0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md). Together they require honest declarations, one checked patch set, full pinned policy, capability-owned IO, and validation before protected effects. The normative [workflow versioning rules](../workflow-versioning.md) additionally require compatible result decoders and rotation for unbounded loops. Keiro's at-least-once step behavior never promises that a call whose result append was lost cannot repeat.

The PostgreSQL suites in `shikigami-core/test-postgres/Shikigami/RouterWorkflowSpec.hs`, `FlowLifecycleSpec.hs`, `WorkflowVersioningSpec.hs`, and `RunEvidenceSpec.hs` already exercise real journals, children, sinks and isolated migrated databases. Add the new acceptance suite beside them rather than using an in-memory workflow imitation. Use Mori to locate Keiro source and public APIs under `mori://shinzui/keiro`; do not copy private journal SQL into production.


## Plan of Work


### Milestone 1: Add the capability and pin the complete policy


Create `shikigami-core/src/Shikigami/Flow/Decision.hs`. Expose an abstract typed `DecisionStep i o` and `decide` operation whose arguments are a registered static slot, an allowed model alias and typed input. Its return type is the slot's validated result. Flow authors cannot supply a credential, provider handler or raw journal name. Add `Decision` to `FlowEffects` and give `FlowDef` a finite inventory of decision slots; existing flows default to no slots. Registry validation rejects duplicate labels, incompatible slot contracts and undeclared aliases before execution. Interpret all external work inside the capability.

Before the new Flow's first decision, journal `decision-policy` containing the complete `DecisionPolicySnapshot` built from the journaled declaration, already resolved profile, compiled slot descriptors and operator model catalog. This captures both triage and investigation slots, including pinned program implementation/schema/validator versions and model option metadata. Secret material is looked up separately through opaque binding identities and never serialized. Later selection can depend on the first journaled result, but cannot expand the snapshot's aliases.

For each invocation, first journal a prepared descriptor with validated input and selected model, then journal a versioned outcome. Journal preparation as `Either DecisionFailure PreparedDecision`, and journal policy resolution as an equivalent bounded success/refusal value, so permanent admission failures replay without fresh catalog reads. Result steps store `DecisionOutcome`; transient transport failures throw before the result append. Preparation makes the exact choice survive a crash during execution; the runner/evidence hooks record actual attempts below it. Read completed result steps before consulting live program implementations or the model catalog. Decode using the recorded schema/validator version's retained pure codec. Never revalidate an old success against a changed current domain policy. A removed implementation may prevent a pending call, but cannot force a completed call to rerun. Unknown historical outcome versions stop with an explicit compatibility error.

Thread the pinned profile and policy snapshot through the workflow runtime. For a decision-only Flow, remove the erroneous requirement that the unused process-default model be sanctioned; check its actual selected models at dispatch. Preserve default-model checks for flows using the existing Routing or PracticeReview evaluator, using explicit compiled Flow requirements or equivalent capability-specific gates. Do not remove their protection as a side effect. Add regression tests where the default is forbidden but both chosen decision models are permitted, plus tests that existing router calls still reject their forbidden default.

### Milestone 2: Register the typed two-model example and validation boundary


Create `shikigami-core/src/Shikigami/Flow/ShikumiDecisionExample.hs`, register `shikumi-decision-example` in `Flow.flowRegistry`, and add typed triage/investigation programs to the decision registry. Triage consumes a bounded request and returns a closed `ReturnNow` or `Investigate` decision; investigation consumes the original input plus typed triage facts and returns a closed return-or-route decision. Use one `Predict` call in triage and at least two sequential `Predict` nodes in the investigation fixture so the integration test proves internal call visibility. Both investigation nodes use the same selected model. Pure domain validators reject unsupported actions, unbounded fields, or invalid result combinations.

Provide `agents/proof/shikumi-decision-example.dhall` with the `triage` and `investigate` aliases and bounded delegates. Provide operator configuration examples for two real catalog models and a deterministic test configuration with two distinct fake model IDs. The proof must drive Handan/Shikumi through the governed provider runner; a fake `evaluateDecision` returning JSON would not prove model propagation or internal evidence.

When investigation proposes specialist routing, include the existing bounded `CandidateCatalog` as validated input. Journal it at `decision-catalog-investigate` before the provider call, decode the proposal through `Router.Decision`, and call `validateRouteDecision` against that exact catalog and the journaled declaration's policy. Reuse governed batch delegation, including current authority checks and reservation semantics at child spawn. Invalid output, no-match and ambiguous outcomes create no child; operational failures remain failures. The Flow alone decides whether to delegate or call Sink/Memory. Program output cannot authorize an effect by supplying an agent or sink identifier.

Wire `DecisionFailure` into the workflow's bounded permanent failure path, leaving transient provider/timeouts retryable under the existing workflow retry policy and preserving asynchronous cancellation. Finalize durable decision evidence for success and bounded failure, using stored facts on replay. Bound the refusal text and avoid raw provider bodies. A failure after an earlier valid decision must keep that earlier call evidence inspectable. Real reviewed-artifact bindings, when supplied through the sanctioned execution context, use the existing evidence finalizer; ordinary runs expose their decision report without fabricating an attestation.

### Milestone 3: Declare and gate the durable shape


Own these new literal labels: `decision-policy`, `decision-prepare-triage`, `decision-result-triage`, `decision-catalog-investigate`, `decision-prepare-investigate`, and `decision-result-investigate`. Add typed envelope declarations and mappings required by the checked workspace. Place the new declared body segment inside patch `shikigami-flow-decisions-v1` and make the runtime call that patch before entering it. For a pre-change instance the false branch preserves the old Flow interpreter/body and makes no decision-policy lookup. A newly registered decision Flow encountered without the patch cannot execute an undeclared new path; return a bounded capability-unavailable failure. Test both branches using old and fresh workflow patch snapshots.

Regenerate, update the hand-owned conformance expectations, and run the full gate against the captured pre-change revision. Include an assertion mapping every compiled decision slot to its exact declared prepare/result labels, and detect any undeclared label. Add the new labels and envelope versions to `docs/workflow-versioning.md`. Do not exploit an undeclarable colon label or invent a declaration that runtime never executes. Do not rename existing workflow names/IDs. The current example is finite; document that repeating a slot in one generation is invalid and that an unbounded authoring extension requires a rotating workflow design with `restoreSeed` and `continueAsNew`.

If the implementer elects the pre-v1 baseline exception instead, first recheck and record all four empty-state/release facts required by that document, revise this plan consistently, and retain the expected `WorkflowBodyChanged` evidence. Default implementation is patch-safe and requires no such exception.

### Milestone 4: Prove replay, crash behavior and complete evidence


Create `shikigami-core/test-postgres/Shikigami/DecisionWorkflowSpec.hs` and register it in `test-postgres/Main.hs` and the Cabal suite. Run an uninterrupted example with triage model A and investigation model B. Assert the first result selects the branch, journals identify all executed programs/models, internal investigation calls are individually visible, and permitted delegation/sink effects occur once. Also run a ReturnNow branch and assert no investigation dispatch or child.

Replay the same workflow ID after changing the default, catalog aliases, provider output and available program implementation. With both results completed, observe identical results/branches and zero new provider calls. Next interrupt after the first result append but before the second preparation, restart with changed catalog/program defaults while retaining the pinned versions, and verify only the pending investigation executes under the original policy. If the pinned implementation or credential binding is removed, verify a bounded unavailable-pinned-decision failure before provider dispatch; no substitution is allowed.

Interrupt after the second preparation and verify selection/input remain fixed. Inject a loss after provider execution but before a result append: allow a repeat attempt and assert evidence retains both actual attempts. Do not assert exactly-once transport in this crash window. Once the result is committed, every replay makes zero additional calls. Inject evidence persistence failure and assert no successful result journal record. Restart the whole collector/store boundary to prove a run-level report is not being reconstructed from surviving IORefs.

Exercise malformed output, domain-invalid output, unknown program and schema, undeclared alias, forbidden thinking, unavailable binding, and a profile allowing only model A. Assert bounded run failures and no subsequent protected effects; the forbidden B selection produces zero B calls. With the two-model profile and proper sanctioned fixture bindings, the shared compliance roll-up accounts for every internal call and reports the expected result. Unresolved attempts or missing terminals cannot pass complete accounting. Verify default-model router behavior, old Flow declarations, children and sinks remain correct.

Write `docs/shikumi-flow-decisions.md` with the compiled example, config/declaration setup, exact commands, recorded evidence expectations, static-label/version rules and crash-window semantics. Update the IR's status/index/log and roadmap only to the status supported by actual completed acceptance, using its bundle contract rather than hand-editing unrelated changes. Distill Decision Logs across all four plans into ADRs and update the master registry only after the full suite and gate succeed.


## Concrete Steps


Run from the repository root. Capture the old shape before editing workflow declarations or bodies:

```bash
DECISION_FLOW_BASE=$(git rev-parse HEAD)
cabal build all
cabal test shikigami-core-test --test-show-details=direct
cabal test shikigami-core-postgres-test --test-show-details=direct
just keiro-gate "$DECISION_FLOW_BASE"
cabal test all --test-show-details=direct
```

Use the repository's configured GHC environment; PostgreSQL tests use the migrated isolated fixture. Gate commands run check, inspect, scaffold, diff and generated conformance. Inspect generated diffs and do not hand-format generated files. For focused iteration name the new Tasty group `Shikumi decision workflow` and run:

```bash
cabal test shikigami-core-postgres-test --test-options='-p "Shikumi decision workflow"' --test-show-details=direct
```

Expected evidence, to replace with actual output during implementation:

```text
uninterrupted: triage model A; investigation model B twice; all three calls accounted
completed replay: zero new provider calls; identical result; no duplicate child or sink
restart between decisions: triage calls unchanged; only investigation runs
forbidden investigation model: zero B calls; bounded failure; no protected effect
lost result append: additional actual attempt preserved; no false exactly-once claim
```

These are acceptance expectations, not tests performed while drafting the plan.


## Validation and Acceptance


IR-12 acceptance 1 is the two-model typed example with a genuine conditional branch and explicit program/step/model journal identities. Acceptance 2 is completed-workflow replay under changed defaults, response and program registry with no new model, child or sink effects. Acceptance 3 is strict result/input/domain rejection and pre-dispatch authorization with bounded outcomes. Acceptance 4 is two-model versus one-model pinned profile tests and all internal program calls in the common run assessment. Acceptance 5 is interruption after the first committed decision and successful resumed completion matching the uninterrupted result. Acceptance 6 is the checked inventory, real patch branches, generated conformance and evolution gate.

Additional cases distinguish pending implementation unavailability from completed replay, and distinguish the provider/append crash window from committed decision replay. Acceptance requires actual database journals and the real runner with deterministic providers; unit fixture success alone is insufficient. Store inspection must show exact parent workflow/generation/static label, program version, selected tuple and every actual attempt. No raw secret marker may appear in journal JSON, diagnostics, reports or telemetry.


## Idempotence and Recovery


Reuse the same workflow ID to test replay and fresh IDs for independent scenarios. Never clear journals to make replay pass. Keep old versioned result decoders and implementation registrations until their supported populations drain; completed outcomes need a decoder even if their executable program is removed. Release changes to program meaning, validators or result schema under new identities and patch/rotation rules, not by overwriting an old registry version.

Keiro does not atomically commit a remote call and its journal append. Provider retries may spend again; the durable evidence ledger must reflect it. Delegation and sinks retain their existing deterministic identities and deduplication boundaries. Following a patch introduction, roll forward rather than deploy a binary incapable of serving the new branch. Production migrations remain additive; test databases can be recreated only through the isolated fixture lifecycle.


## Interfaces and Dependencies


The new Flow interface has the semantic shape `decide :: Decision :> es => DecisionStep i o -> ModelAlias -> i -> Eff es o`. Slot constructors and labels come only from compiled registrations. The interpreter receives `DecisionPolicySnapshot`, the original `ResolvedProfile`, runtime credential bindings, the typed program registry, the governed runner, and durable evidence callbacks. It produces `PreparedDecision` and `DecisionOutcome` journal envelopes using the contract versions from `docs/plans/73-define-typed-decision-programs-and-authorized-model-catalogs.md`. Flow bodies receive neither IOE nor Store.

`docs/plans/74-run-shikumi-decisions-through-governed-provider-calls.md` owns provider execution and actual-call checks; `docs/plans/75-persist-decision-call-evidence-across-retries-and-restarts.md` owns attempt allocation, normalized facts, stored reports and common evidence evaluation. This plan owns journal labels, runtime wiring, typed example registrations and all end-to-end acceptance. Any needed change to a shared descriptor, hook, or persistence contract must be reflected in its owning child and in the master Integration Points before use.
