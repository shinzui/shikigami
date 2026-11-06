---
id: 13
slug: compose-shikumi-decisions-in-durable-flows
title: "Compose Shikumi decisions in durable Flows"
kind: master-plan
created_at: 2026-09-26T18:34:11Z
intention: "intention_01m3fft4cceb1ba9t3fammx5x4"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T18:34:11Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-21T20:30:29Z
      mode: "update"
      note: "Coordinate Shikumi MP-12 without blocking current scope; bind parameter state and derivation, preserve committed results and distinguish probability data from call evidence"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:00:35Z
      mode: "update"
      note: "Apply review: refresh to plan 80 cohort and HTTP provider seam; EP-1 owns Behavior.Provider predicate and FlowDef slot inventory; add MP-14 plan 82 consumer; narrow EP-3 prerequisite to EP-1 M1 and M3"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T20:30:58Z
      mode: "implement"
      note: "Begin implementation with plan 73; preserve dependency order and pinned intention"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T20:49:07Z
      mode: "update"
      note: "Reconcile the registry and completion summary with plan 74 reopened failure-path acceptance."
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T00:41:18Z
      verdict: "changes-requested"
      note: "Dependency context predates plan 80 (UseHttp, Behavior.Compatibility, Baikai 0.7.2.0); Behavior.Provider predicate and FlowDef slot inventory ownership split across EP-1/EP-2/EP-4; MP-14 plan 82 catalog consumer absent from Integration Points"
---

# Compose Shikumi decisions in durable Flows


This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope


Implement [IR-12](../improvement-requests/compose-shikumi-decisions-in-durable-flows.md): a compiled Haskell Flow invokes registered, typed Shikumi programs at named decision points, chooses an authorized model for each invocation, and branches on validated results. A demonstration triages with one model, optionally investigates with another, and returns or delegates through the existing governed boundary. A completed decision replays without model calls; its original program, input, model tuple, policy, and result remain inspectable after configuration changes.

A Flow is a compiled function interpreted inside the agent-run durable workflow. A journal stores named step results so a restarted worker can resume. A model tuple means provider, API, endpoint class, exact model ID, and thinking setting. The tuple grants no authority by itself: operator catalog membership, the journaled agent declaration, and any pinned sanctioned profile must all permit it. Model output proposes data; Haskell validation and the existing effect capabilities control execution.

Shikumi is the Haskell library of typed language-model programs; a program carries an input and an output type, and its nodes may only call a model or raise a typed error. `Shikigami.Program.Runtime` is the local runtime that executes Shikumi complete/stream calls; plan 124 removed Handan. Baikai is the provider client library that owns models, options, provider registries and call evidence. Keiro is the durable workflow engine that journals steps, and Settei is the configuration library behind `Shikigami.App.Config`. The selected stack now supports TypeSafe closed-set judgments; additional calibration/optimizer work remains outside this initiative.

Scope includes a typed decision registry, operator model catalog, per-agent model allow-list, an isolated provider runner, durable accounting for every provider attempt, versioned decision journals, workflow declarations and gates, and a tested authoring example. It excludes per-node model selection, arbitrary provider identifiers from payloads, visual editing, IR-7 signing/read-API completion, and changing existing router semantics. Every actual call inside a program remains individually accounted for even though model selection is per invocation.

The Flow-facing contract belongs to Shikigami: a typed static decision slot, an authorized model alias and typed input produce a validated typed result. Shikumi and Baikai APIs remain behind the local registry and runner adapter; this boundary does not assume their APIs will never change. Typed/structured output is already integrated by the current consumer; additional probability adapters and calibration remain outside this closeout.


## Decomposition Strategy


Four work streams separate admission, execution, evidence persistence, and durable orchestration. Admission can be tested without a provider. Execution can be tested with an in-memory evidence callback. Persistence can be tested with provider evidence fixtures. Orchestration consumes all three and proves the complete request through the real workflow and PostgreSQL harness. Combining the runner with workflow evolution would obscure the independent provider and replay failure boundaries; splitting by Haskell files would create shared ownership without independently useful behavior.

The typed registry, catalog, provider runner, evidence store and durable Flow
consumer are implemented. `Shikigami.Program.Registry` now has local ProgramTask
behavior wrappers; governed decisions use `Program.Decision` and `Program.DecisionRunner`.
Only plan 74 M3's remaining stream/failure qualification is open. Do not rebuild
these owners or restore the former Handan pin.

Current selection in `cabal.project` is index `2026-11-03T12:48:57Z`, Shikumi
0.5.1.0, tools 0.4.2.1 and Baikai 0.10.0.0/vendors 0.7.3.0, alongside Keiro 0.22
and Kioku 0.12.0.2. Hackage and selected peeled tags were verified on 2026-11-06.
Plan 124 records 19 runner/742 pure core and 1,829 application cases plus five
native role builds on its named candidate; that does not close the untested
unterminated-stream success path. No dependency upgrade is required by this closeout.
Sources are owned by `mori://shinzui/shikumi` and `mori://shinzui/baikai`;
source-file artifact URIs are pending.

Plan 80 also changed the provider seam the children build on. `ProviderSelection` in `Shikigami.App.Config` now has `UseStub`, `UseAnthropic`, and `UseHttp` with typed Baikai options and an opaque credential; `behavior.provider` selects the stub, Anthropic Messages, OpenAI Chat Completions or OpenAI Responses, and models decode against the selected API's generated catalog. `Shikigami.Behavior.Compatibility` validates actual options and requests before dispatch, `Shikigami.Behavior.Provider.newBehaviorEnvFor` is the one composition boundary, and `providerCall` projects the actual model and options into the `ProviderCall` tuple that `matchesCall` checks against the pinned profile. EP-1's catalog reuses those catalogs and option types; EP-2's runner runs the compatibility check on its final request.

Relevant local decisions consulted are [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md) (honest declarations), [ADR 0004](../adr/0004-one-options-value-and-a-checked-patch-set.md) (one workflow options owner), [ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md) (pinned policy), [ADR 0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md) (atomic evidence and encode-only provider records), [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) (declared body evolution), [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) (Flow effects), [ADR 0023](../adr/0023-delegation-is-governed-at-the-child-spawn-boundary.md), [ADR 0028](../adr/0028-a-router-catalog-is-a-bounded-snapshot-of-declared-authority.md), [ADR 0029](../adr/0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md), and [ADR 0040](../adr/0040-response-options-and-foreground-launches-have-separate-authority.md) (HTTP response options carry their own authority, separate from foreground launches). The normative [workflow versioning rules](../workflow-versioning.md) govern all workflow changes. Historical ADR text describing retired patches does not override the current body.

Cross-repository research also read the request-default decision `mori://shinzui/shikumi/okf/adrs/concepts/ADR-12` and transport-accounting decision `mori://shinzui/shikumi/okf/adrs/concepts/ADR-13`. Both handles resolve through `mori path` and `mori registry concepts --id` as of 2026-10-21. Their relevant constraints are embedded here: fill-only request defaults are not authorization; billing observations omit full call evidence and use process-local IDs; cache hits are not provider calls. The runner must enforce the final options and collect actual terminal evidence below internal retries.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Typed programs and authorized model catalogs | docs/plans/73-define-typed-decision-programs-and-authorized-model-catalogs.md | None | None | Complete |
| 2 | Governed Shikumi provider execution | docs/plans/74-run-shikumi-decisions-through-governed-provider-calls.md | EP-1 | None | In Progress (M3 reopened 2026-10-29; streaming failure-path qualification remains) |
| 3 | Durable decision call evidence | docs/plans/75-persist-decision-call-evidence-across-retries-and-restarts.md | EP-1 M1 and M3 (typed contracts and call hooks) | None | Complete |
| 4 | Durable Flow composition and acceptance | docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md | EP-1, EP-2, EP-3 | None | Complete |

EP numbers above identify registry rows; filenames contain repository-wide plan IDs. Status values are Not Started, In Progress, Complete, and Cancelled.


## Dependency Graph


EP-1 defines the descriptor, typed program registry, model selection, and callback contracts consumed by both EP-2 and EP-3. EP-2 needs the whole of EP-1 because it dispatches a resolved selection. EP-3 needs only EP-1's accepted milestone 1 (typed contracts and durable identities) and milestone 3 (call hooks and fake evidence); it may start before EP-1's catalog milestone is complete. Those two plans then proceed independently: EP-2 proves execution against fake callbacks; EP-3 proves persistence against typed evidence fixtures. They have an integration dependency on the same begin/finish callback contract. EP-4 needs the real runner and store together before enabling the production capability.

```text
EP-1 (73) -> EP-2 (74) --+
          -> EP-3 (75) --+-> EP-4 (76)
```

The completed declarations/catalog/router work in `docs/masterplans/8-declarative-router-agents.md` and the implemented profile and evidence core in `docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md` and `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` are existing prerequisites. The unfinished signing and endpoint work in `docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md` is not a hard dependency. It remains coordinated by `docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md`. This initiative consumes the evidence core and must not claim an ordinary run has a reviewed-artifact binding it was never given.

`mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs`
has delivered upstream structured/judgment output support, now adopted through local
plans 80/124. Current acceptance preserves actual TypeSafe answers and retained result
codecs. Calibration/optimizer work and any additional probability capability remain
separate; no absent Handan adapter or unreleased Baikai-0.8 assumption gates this plan.

`docs/masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md` is a downstream consumer. Its child `docs/plans/82-pin-governed-execution-settings-for-agent-assignments.md` declares EP-1 a hard external dependency, reuses `Shikigami.Decision.ModelCatalog` as the single operator alias registry for whole-run model selection, keeps whole-run permissions distinct from decision-slot permissions, and may extend the public model descriptor additively. Its plan 85 owns the Flow invocation regression that needs EP-2 through EP-4. Nothing in that initiative blocks this one, but a descriptor or predicate change here must be reflected in plan 82 before it is relied on there.


## Integration Points


EP-1 owns new modules `shikigami-core/src/Shikigami/Program/Decision.hs` and `shikigami-core/src/Shikigami/Decision/Contract.hs`. They define typed program references, immutable implementation/result-validator identities, serializable decision descriptors, bounded failures, and the begin/finish call callbacks. EP-2 implements the execution side; EP-3 implements storage callbacks; EP-4 composes them. Changing a persisted identity means a new version, never overwriting a registry key.

EP-1 also owns parameter-state identity: a versioned digest of the registered program's complete effective parameter state, including every node's instruction override and demonstrations, plus the version of local result derivation and its effective defaults. Future decision thresholds, cuts and weights must join that identity when supported. The policy snapshot, prepared decision and evidence references carry these identities; the immutable registration retains the matching executable and state. A request/cache key or structural program shape is insufficient because local settings can change an answer without changing either. EP-2 verifies a pending invocation against the full pinned identity; EP-3 stores it without reinterpreting it; EP-4 pins it for every slot before the first invocation. [ADR 0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md) records this boundary.

EP-1 owns `shikigami-core/src/Shikigami/Decision/ModelCatalog.hs`, the `decisionModels` agent allow-list, `schema/Agent.dhall`, and the operator catalog configuration in `Shikigami.App.Config`, built on the per-API model catalogs and typed response options that plan 80 added there. The public model descriptor has two consumers: EP-2 dispatches it, and plan 82 under MasterPlan 14 references it for whole-run selection, so it must carry alias, descriptor version and digest, provider, API, endpoint class, exact model, explicit thinking preference, and an opaque binding identity and version; HTTP option compatibility stays in `Behavior.Provider` and `Behavior.Compatibility`. EP-4 threads the resolved catalog through the worker and one-off agent runtime. EP-2 consumes a resolved selection and rechecks actual provider options. Secrets and provider handlers stay process-local; journals contain immutable descriptor identity and an opaque credential binding only. Missing or changed bindings cannot fall back to process defaults.

EP-1 also owns the refactor of the profile tuple predicate in `Shikigami.Behavior.Provider`: `providerCall` and `matchesCall` become reusable over an actual model and options pair, or over a descriptor's declared tuple, without constructing a `BehaviorEnv`. EP-1 uses it for admission; EP-2 calls it on the final options of every attempt; plan 82 calls it for whole-run selection. `constrainBehaviorEnv` and `newBehaviorEnvFor` keep their existing callers and semantics. EP-2 does not reshape the predicate; a gap found at dispatch is reported back to EP-1 as a contract change.

EP-1 owns the finite decision-slot inventory on `FlowDef` in `shikigami-core/src/Shikigami/Flow.hs`, defaulting to no slots for existing flows, together with the pure validation in `Flow.flowDeclarationErrors` and registry construction: duplicate slot labels, slot contracts that do not match the typed program registry, and slot aliases the declaration does not authorize are rejected without a runtime. EP-4 owns `FlowEffects`, the `Decision` effect, and `shikigami-core/src/Shikigami/Flow/Decision.hs`, and reads that inventory to compile the policy snapshot; it does not redefine the inventory.

EP-2 owns `shikigami-core/src/Shikigami/Program/DecisionRunner.hs`. An invocation uses the local ProgramRuntime and a private registry with an authorized wrapper around the selected real handler; the wrapper forwards every `ApiProvider` field of the selected Baikai 0.10.0.0 handler, including `structuredOutput`, sits below Shikumi retries, and captures each actual attempt. Before dispatch the wrapper runs EP-1's tuple predicate and `Shikigami.Behavior.Compatibility` on the final model, options and request. No process-global registry mutation changes another run's model or credential. The existing timeout, retry, rate, tool, and profile limits remain effective.

EP-3 owns new `shikigami-core/src/Shikigami/Decision/Evidence.hs`, additive attempt-ledger migrations, and extensions to `Shikigami.Attestation.Evidence`, `Compliance`, and `EvidenceStore`. The shared opaque token permits UUID generation before the transaction and ordinal assignment under the run lock; finish checks both. The ledger records expected calls before dispatch and terminal evidence before a successful decision can be journaled. Full Baikai evidence stays encode-only JSON; restartable compliance uses an explicitly versioned Shikigami fact record derived from typed provider evidence. Both live and restarted roll-ups use one evaluator. EP-4 supplies stable parent run/workflow/generation/decision identities and invokes finalization; it never invents reviewed-artifact metadata.

Probability/confidence data in a registered output is validated result data preserved by EP-1's versioned result codec and EP-4's outcome journal. It cannot satisfy EP-3's provider-attempt or compliance-evidence requirements. A completed outcome is decoded with its retained codec, never recomputed from provider evidence under new parameters. EP-4 owns a regression using current APIs that changes local derivation while leaving the provider response unchanged and proves both completed-result reuse and pending-state pinning.

EP-4 owns `shikigami-core/src/Shikigami/Flow/Decision.hs`, `FlowEffects`, workflow wiring, program and flow example registrations, `domain/shikigami/agent-run.keiro`, generated conformance expectations, and authoring documentation. It journals one complete decision-policy snapshot for the Flow and preparation/result steps for each call site. The snapshot binds all declared decision slots, including slots not yet executed, so changing a deployment between decisions cannot reinterpret the pending one. A completed step is read before consulting a live registry; pending steps require the pinned implementation and credential binding to remain available.

Each plan adds only its own module/test entries to `shikigami-core/shikigami-core.cabal` and test entry points. EP-1 is the owner of shared contract changes. EP-4 is the integration owner of all cross-plan amendments and the sole owner of workflow labels. Relevant durable decisions must be distilled into local ADRs during implementation, especially whole-Flow pinning, model authorization, private provider registries, crash accounting, and encode-only evidence recovery.


The integrated consumer also uses EP-1's additive typed pinned-reference recovery, explicit historical result-codec constructor and retained-binding lookup. Active aliases and retained binding versions have separate authority; EP-4 owns their replay qualification.


## Progress


2026-11-06 reconciliation: three children are Complete; EP-2 (plan 74) remains In
Progress following its 2026-10-29 review. Its M3 requires missing-terminal
enforcement and the remaining cancellation, terminal-write, retry and refusal
fixtures. The current runner still returns a validated output after normal
program completion without checking that every begun stream persisted a terminal.
This source check is not a newly executed regression test.

The 2026-10-25 production wiring, typed two-model example, 225 PostgreSQL cases
and additive workflow gate against `436e9f8` remain historical acceptance
evidence. EP-4's completed integration work does not discharge EP-2's reopened
contract or waive it as a prerequisite for new dependent work. Finish plan 74's
focused and full-core checks plus its PostgreSQL consumer regressions before
closing the initiative. Plan 124 has since replaced Handan with the local
Shikumi runtime; old Handan/dependency decisions retained in the Decision Log describe their named checkpoints.
Plan 85 has also delivered `runDecisionAccepted` and per-actual-call root hooks;
M3 must preserve those consumers and structured complete/stream output.



## Surprises & Discoveries


2026-10-25: Admission is independently executable on the selected Shikumi 0.4.0.0/Baikai 0.7.2.0 cohort. `Behavior.Provider.Call` holds the reusable pure predicate to avoid a configuration/runtime import cycle; `Behavior.Provider` re-exports it. Plan 74 consumes this seam. Plan 73 requires demonstrations in serializable `Params` because signature-level existential dictionaries lack JSON encoders; see ADR 0041.


2026-10-25: End-to-end qualification separates active model authority from retained historical bindings and executable availability from historical pure codecs. The typed pending-reference recovery remains an additive EP-1 API. The decision-only Flow's explicit ambient-model requirement preserves existing router/review checks. ADR 0045 records this integration boundary.


## Decision Log

2026-10-25: Keep transport metadata compatibility intact. Correlation on APIs that reject arbitrary metadata remains in the evidence request and durable token-to-terminal association; final options pass the existing compatibility gate. The wrapper is below Shikumi retries and preserves all provider capability fields. See ADR 0043.


2026-09-26: Split admission, execution, evidence, and workflow integration into four plans. The runner and evidence store have separate observable contracts and can be validated independently after admission types exist.

2026-09-26: Use a new typed decision registry and Handan's configurable runtime with private Baikai handlers. The arbitrary `Task.taskRun :: ... -> IO Envelope` boundary cannot guarantee decision-only effects or typed output. Public released APIs are sufficient; no upstream fork is planned.

2026-09-26: Pin the complete finite decision policy before the first invocation, then journal each invocation's selected descriptor and validated result. Pinning only completed results leaves a pending second decision vulnerable to catalog/program drift after a restart.

2026-09-26: Separate durable decisions from actual provider attempts. Keiro steps are at-least-once across the action/append crash window. Completed decision replay makes zero new calls, but a lost append can require a new provider attempt, which must be separately recorded rather than overwritten or called exactly-once.

2026-09-26: Keep IR-7's reviewed-artifact requirements honest. Persist ordinary run decision evidence and reuse its call-compliance evaluator; only an explicitly supplied valid review binding can participate in the existing sanctioned attestation lifecycle.

2026-10-21: Coordinate with `mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs` without adding a hard dependency. Pin effective parameter state and derivation semantics, preserve committed outcomes independently of upstream cache/trace re-derivation, and keep probability data separate from execution evidence. Revision: clarify the adapter and identity contracts across plans 73–76 so implementation can proceed on current APIs; Jev and calibration remain outside acceptance. See ADR 0041.

2026-10-21: Review revision after plan 80. Refresh dependency facts to the pinned Shikumi 0.4.0.0 and Baikai 0.7.2.0 cohort and to the HTTP provider selection and compatibility gate that plan 80 added. Give EP-1 sole ownership of the `Behavior.Provider` tuple predicate refactor and of the `FlowDef` slot inventory and its validation, because EP-1 is first in dependency order and both are needed for admission; EP-2 and EP-4 consume them. Record plan 82 under MasterPlan 14 as an external consumer of EP-1's catalog, descriptor and predicate. Narrow EP-3's prerequisite to EP-1 milestones 1 and 3 so persistence work need not wait on configuration loading. EP-4 stays whole: the example Flow is the only end-to-end proof of the capability, and its labels and patch must land with the capability they guard. No ADR changes; the boundaries in ADR 0028, ADR 0040 and ADR 0041 are unchanged, and the ownership choices are plan coordination.


## Outcomes & Retrospective


In progress after reconciling plan 74's reopened M3. Its evidence-completeness
and failure-path acceptance must pass before this MasterPlan is Complete. The
following records the original delivery, not a claim that the reopened work has
been qualified.

The 2026-10-25 qualification completed the six IR-12 acceptance cases through the registered two-model example and real Handan/Shikumi, PostgreSQL journals and governed effect boundaries. All packages built and tested successfully; key suites included 453 core unit, 225 PostgreSQL, 37 agent, 88 worker and 47 server cases. The real patch, generated artifacts and evolution gate passed against `436e9f8` with no breaking finding and replay-neutral impact. The authoring guide, proof declaration and IR status/index/log/roadmap were updated.

ADR distillation reviewed every child's Decision Log, Surprises and Outcomes. ADR 0041 now carries implementation evidence for complete program-state identity and retained rich results; ADR 0042 owns intersected authority; ADR 0043 owns actual-attempt dispatch; ADR 0044 owns restartable facts and conservative uncertainty; ADR 0045 owns whole-Flow pinning, historical resolution and checked labels. The original four-way decomposition held; integration needed only additive registry/history seams.

Initiative-level environment friction FRIC-1 is accepted with an isolated Kikan source checkout and temporary Cabal project. This preserves the repository's dependency declarations and the registered older checkout. Child-specific fixture concurrency and archive mirror detours are triaged in their owning plans. No friction entry remains logged. Completed replay is call-free; execution before an uncommitted result can repeat and remains fully accounted. Live HTTP model execution, optional probability/calibration adapters and downstream signing/read APIs are outside the validated example's scope.

Revision note (2026-11-06): Rebase current architecture and integration on local ProgramRuntime, selected released structured-output cohort and completed accepted/root-accounted decisions; retain historical results and the genuine plan-74 failure-path gate.
