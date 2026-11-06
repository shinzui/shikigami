---
id: 46
slug: orchestrate-review-delivery-and-end-to-end-conformance
title: "Orchestrate review delivery and end-to-end conformance"
kind: exec-plan
created_at: 2026-07-26T04:38:47Z
intention: "intention_01kyeb9heqecv8041cmwqwqg3q"
master_plan: "docs/masterplans/9-architecture-practice-review-flow.md"
provenance:
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T21:09:33Z
      mode: "update"
      note: "Reconcile current allocation/ingress/corruption coverage and reopen overstated conformance/operational closeout."
---

# Orchestrate review delivery and end-to-end conformance

This living plan was refreshed against `ff00b819` on 2026-11-06. It is In Progress.
Earlier implementation/test counts are historical evidence, not current full acceptance.

## Purpose / Big Picture

A declared architecture-practice router should delegate a pinned trigger to the
OpenTelemetry reviewer, which records an advisory evidence-bearing verdict, Kawa
history and one semantically coalesced owner attention item when required. Authorized
resolutions preserve adjudication history. Replay must use retained evidence/results
without repeated model, memory or sink effects. These are read-only reviews with no
workspace mutation, merge-block or approval-gate authority.

The Flow and its interpreters are implemented. Completion requires the existing safety
repairs and full routed/profile/delivery/identity matrix, then a released live content
reader and deployment proof. This plan consumes repairs 60–63 rather than rebuilding the
router, review memory, profile resolution, allocation receipts or sink ledger.

## Progress

- [x] (2026-08-26; current wiring inspected 2026-11-06) M1: registered specialist Flow, proof declarations, read-only execution context and production interpreter wiring exist. Current declarations use the accepted baseline rather than the retired review patches.
- [x] (2026-08-26; extended by plan 107) M2 implementation: journaled evidence/evaluation, review memory and strict authorized input dispatch exist; review identity reservation and ID-free resolution admission now use durable allocation receipts.
- [x] (2026-08-26) M3 implementation: typed history, recipient mapping, reservation/outbox/receipt publication exist. This does not certify the still-open skip/resume or label-independent coalescing defects in plan 60.
- [ ] M4: accept safety repairs 60/61 and the full plan-63 routed proof-declaration, provisioned-profile, sink-delivery, recorded-identity and semantic-key matrix; update reviewed coverage with named evidence.
- [ ] M5: finish plan-62 provisioning/operator guidance, install the released Kikan reader, and prove exact-revision acquisition and call-free replay through a configured deployment.

The 2026-11-06 refresh reconciles documentation, not runtime acceptance. Kikan
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5` remains proposed.
Local deterministic repair work may proceed; a live reader cannot be inferred from the
existing generic workspace provider.

## Surprises & Discoveries

The original closeout overstated coverage. The current orchestration suite is
`shikigami-core/test-postgres/Shikigami/PracticeReviewOrchestrationSpec.hs`, not the
pure core test tree. It includes strict receipt checks, one real ingress enqueue,
frozen attention vectors, five classifications and four resolution outcomes, one real
AgentRun fixture, incomplete-evidence replay, concurrent reservation and corrupt-retained
attention recovery. It does not establish the whole plan-63 matrix merely by passing.

`PracticeReview/Authorization.hs` already redacts submission Show and binds schema-2
receipts to the full ID-free request. `PracticeReview/IdentityStore.hs` owns allocated
review/resolution entities. Owner-or-authority entitlement remains absent. The valid
JournalAlreadyPresent branch still returns without condemning speculative reservation
writes. Claim labels still influence the version-1 semantic projection. These remain
real plan-60/61 acceptance work despite later domain hardening.

`Workers/Config.hs` installs `failClosedPracticeReviewRuntime`. Its content reader reports
unavailability, with no ambient Git/workspace fallback. Review interpreters and identity
reservation are already declared in `domain/shikigami/agent-run.keiro`; the historical
review patch ids have been retired under an earlier accepted first-release baseline.
Do not add them back or use their removal as permission for another baseline reset.

## Decision Log

2026-11-06 refresh: preserve the delivered specialist, routed advisory contract and
history/attention ownership. Reopen the overstated M4/M5 completion against REV-1/2/4/7
and the current suite, consume ADRs 92/93 allocation and full-request receipts, and use
the actual domain path. Repairs keep their existing owners in plans 60–63.

The dated decisions below preserve original rationale. Deterministic application IDs,
old patch instructions and absent-interpreter observations are superseded by current
Context and ADRs 92/93; semantic/replay obligations remain.

- Decision: Keep the existing router and add only the specialist Flow. The router continues to
  own catalog snapshotting, model-assisted selection, reservation, delegation, and child waits;
  the specialist owns evidence, judgment, review memory, history, and attention.
  Rationale: Plans 40 through 42 already delivered and tested this authority boundary. Rebuilding
  or narrowing it here would discard the multi-candidate routing proof.
  Date: 2026-08-26. Supersedes the July instruction to register both Flows.

- Decision: Decode the specialist input as either one raw validated version-1 trigger or one
  versioned `AuthorizedPracticeReviewResolution` envelope. Review triggers select exactly one
  `opentelemetry` adoption and remain unchanged through the router. Resolutions are addressed
  directly to the specialist and bare resolution JSON is rejected.
  Rationale: The trigger must preserve the landed producer/router contract. A resolution needs a
  durable proof that its resolver was authenticated or that an approved artifact workflow produced
  it; `RunJob.identity` cannot provide that proof because it identifies the reviewer agent.
  Date: 2026-08-26.

- Decision: Supply parent/child workflow and Kioku session lineage through a read-only
  `PracticeReviewExecutionContext` built from the journaled job and current workflow.
  Rationale: Lineage is execution metadata, not producer input. This preserves the no-specialist,
  unchanged-payload rule while satisfying verdict validation.
  Date: 2026-08-26.

- Decision: Journal one bounded, versioned `EvidenceBundle` snapshot and one raw evaluator value
  under static labels. If evidence is incomplete, construct and validate `unresolved` from the
  structured acquisition problems and do not invoke the evaluator.
  Rationale: Acquisition already validates all pinned reads and reduces them to bounded data.
  Journaling that result captures mutable-ref resolution before use without multiplying step
  topology. A model cannot repair missing provenance.
  Date: 2026-08-26. Refines the 2026-07-25 incomplete-evidence decision.

- Decision: Implement the evaluator as a narrow capability backed by AgentRun's `BehaviorEnv` and
  resolved sanctioned profile, following the raw-value-then-strict-validation pattern in
  `Shikigami.Flow.Routing`. Extend `behaviorEnvForProfile` so a Flow that declares a profile is
  constrained before its interpreters receive the environment. Do not claim a landed Shikumi task
  or add a second provider configuration path.
  Rationale: The proof declaration's `noop-summary` task is not a review evaluator. The runtime
  already owns model choice, credentials, tracing, and durable profile resolution.
  Date: 2026-08-26.

- Decision: Record review memory first, enqueue Kawa review history second, and reserve/enqueue
  attention third. A resolution updates memory before enqueueing its Kawa resolution activity.
  Rationale: A completed semantic result must be durable before it becomes externally visible.
  Kawa history is emitted for every distinct review; owner interruption is conditional.
  Date: 2026-08-26. Preserves the 2026-07-25 history-before-attention decision.

- Decision: Make the attention key independent of `ReviewId`, workflow id, run id, and revision
  names. Hash the logical target/practice scope, classification, owner role, resolved recipient,
  sorted normalized material claims, recommended action, and sorted cited evidence content
  identities. For incomplete evidence, include normalized acquisition problems as claims.
  Rationale: `ReviewId` is trigger-specific and cannot coalesce equivalent disputes across runs.
  The semantic projection does coalesce byte-identical evidence and claims while allowing changed
  classification, recipient, claim, action, or cited content to create a new item.
  Date: 2026-08-26. Supersedes the 2026-07-25 lineage-root formulation.

- Decision: Store only logical attention reservation data and the winning outbox message id in
  `shikigami.practice_review_attention`. Join that id to `shikigami.sink_deliveries` for delivery
  status and the downstream signal id; never copy those fields into the reservation.
  Rationale: ADR 0022 assigns delivery truth to the receipt table. One authority also makes repair
  and redelivery behavior unambiguous.
  Date: 2026-08-26.

- Decision: Atomically append the `practice-review-attention` journal result, win the reservation,
  enqueue the prepared Kizashi outbox message, and create its pending delivery receipt in one
  database transaction. A losing reservation journals `Coalesced` and enqueues nothing.
  Rationale: A reserve-then-emit sequence has a crash window that can permanently suppress the
  only signal. Existing `prepareSinkIntent` and `enqueuePreparedSinkIntentTx` provide the correct
  outbox and receipt boundary.
  Date: 2026-08-26.

- Decision: Resolve semantic owners through a boot-validated configuration map whose keys are one
  owner principal or a sorted joint-owner set and whose values are Kizashi `recipient_...` ids.
  Missing or invalid mappings fail the attention operation before reservation. Do not use the
  global Kizashi fallback and do not open Danwa conversations in this first slice.
  Rationale: Kizashi has one recipient; review contracts allow semantic and joint owners. An
  explicit map yields at most one correct operational destination without expanding the contract
  or pretending an ownership directory exists.
  Date: 2026-08-26.

- Decision: Keep live content-plane acceptance gated by
  `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`. Until then, production composition
  installs an explicit unavailable reader that produces deterministic incomplete evidence; it
  never falls back to ambient Git or the host workspace.
  Rationale: The specialist can be exercised and deployed fail-closed before the external content
  plane is ready, while the plan cannot honestly claim live revision-pinned evidence.
  Date: 2026-08-26. Carries forward the 2026-07-30 gate.

- Decision: Permit uncited acquisition-problem claims only on `Unresolved`; retain citation and
  target/reference evidence requirements for every semantic classification.
  Rationale: Content-plane failure is itself the reason judgment is unavailable. Requiring missing
  content as evidence would force either a fabricated citation or an operational failure instead of
  the contract's explicit fail-closed classification.
  Date: 2026-08-26.

- Decision: Derive the attention outbox message id from the semantic attention key before entering
  the reservation transaction, while preserving the step-derived wrapper for other sink callers.
  Rationale: winner selection, outbox insertion, receipt creation, and the exact journal result must
  commit atomically, and every equivalent run must address the same delivery identity.
  Date: 2026-08-26.

## Outcomes & Retrospective

Core orchestration is delivered; full acceptance is open. The original 2026-08-26
serialized run recorded 801 cases and an additive gate at `8e0df55`; those counts and
patches describe that historical candidate. Later domain/adapter qualifications do not
prove the missing routed/delivery/entitlement cases. Existing source now includes
allocated identity/ingress and corruption controls beyond the original nine orchestration
cases, which must be retained. This refresh ran no model or service trial.

## Context and Orientation

Domain contracts are in `shikigami-core/src/Shikigami/PracticeReview.hs`. Triggers,
classification, cited evidence, owner/applicability and outcome validators are shared.
`PracticeReviewResolutionRequest` is ID-free; the memory owner allocates the resolution
and returns the recorded entity. `PracticeReview/IdentityStore.hs` retains identity
allocation receipts. The Flow calls `reserveReviewIdentity` before evidence/evaluation.
Do not derive or accept a model/caller-selected ReviewId or ResolutionId.

`Flow/OpenTelemetryPracticeReview.hs` is registered by `Flow.hs`. The proof manifests
are `agents/proof/architecture-practice-router.dhall` and
`agents/proof/opentelemetry-practice-reviewer.dhall`. They already select the router and
reviewer Flow; do not change a supposed noop-summary specialist. The reviewer pins
`sanctioned-review` version 1 and suppresses generic automatic output recording/sinks.
`PracticeReview/Capability.hs` supplies bounded evidence/evaluation ports and execution
context; Memory.hs owns journaled memory transitions; Attention.hs owns reservation,
association and journal/outbox/receipt atomicity. `Agent/Workflow.hs:runFlowBehavior`
installs these current interpreters directly. All paths above are under
`shikigami-core/src/Shikigami/`.

`Sink/Intent.hs` prepares guarded intents and `Sink/Delivery.hs` owns downstream receipt
truth. Attention is never a second delivery status store and a failed/unknown delivery
does not release a semantic reservation. Kawa history and Kizashi attention use the
recorded reviewer identity. Config owns the explicit semantic-owner recipient map.

Read the current [workflow guide](../workflow-versioning.md),
[ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md),
[ADR 0031](../adr/0031-practice-review-adjudication-is-a-logical-memory-transition.md),
[ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md),
[ADR 0034](../adr/0034-review-resolutions-enter-as-verified-durable-envelopes.md),
[ADR 0035](../adr/0035-practice-review-attention-reserves-semantics-not-delivery-state.md),
[ADR 0092](../adr/0092-review-values-are-checked-and-source-citations-use-structured-coordinates.md)
and [ADR 0093](../adr/0093-review-entities-are-allocated-behind-durable-request-receipts.md).
The latter two supersede historical scalar/identity claims without discharging resolver
entitlement or semantic attention defects.

## Plan of Work

### M1–M3 — Preserve delivered orchestration

Keep the existing router catalog, unchanged payload delegation, admitted recorded lineage,
profile-constrained evaluator, bounded evidence snapshot and raw-proposal journal. Missing
evidence yields validated Unresolved without an evaluator call; it never fabricates a
citation. Preserve immutable review allocation, provisional/adjudicated memory and one
history event per semantic transition. Unknown contracts or provider/store failure remain
operational failures, not successful semantic classifications.

Keep current declared labels/result codecs and old accepted results. Any Agent/Flow body
change follows workflow versioning against the actual pre-change baseline. Do not recreate
old review patches or re-run identity allocation from model text during replay.

### M4 — Close repair and full deterministic conformance

Implement and accept
[plan 60](60-harden-practice-review-attention-reservation-and-specialist-failure-boundaries.md)
for skip/resume atomicity, label-independent versioned attention keys, stable problem
rendering, permanent input failure, scoped re-review and bounded proposals. Implement
[plan 61](61-enforce-practice-review-resolver-entitlement-and-harden-the-authorization-envelope.md)
for ingress owner/authority entitlement, a newly versioned receipt, pure retained
Flow-side recheck and source hardening. Existing submission redaction/full-request binding
are regression foundations, not tasks to undo or recreate.

Then accept [plan 63](63-extend-practice-review-conformance-to-the-claimed-end-to-end-matrix.md):
the real proof router delegates to the reviewer; the exact reviewer profile resolves;
Kawa/Kizashi scripted delivery exercises retry, permanent rejection, lost acknowledgement
and receipt recovery without releasing reservations; verified/compatibility/unresolved
identities enforce their distinct behavior; renamed/reordered claim labels coalesce while
material changes produce distinct keys. All five verdicts, both exception-approval branches
and four resolution outcomes retain exact artifacts/citations and recorded lineage.

A transport retry may produce multiple HTTP attempts while retaining one logical
outbox/receipt identity. Kizashi has no claimed exactly-once remote POST guarantee;
unknown outcomes need reconciliation. Count attempts and acknowledged effects separately.
Keep each failure case tied to its real owner window, with no false success from a stub.

### M5 — Operational closeout and live pinned content

Complete [plan 62](62-make-the-practice-review-closeout-and-operator-documentation-true.md)
profile install/show and actual operator guidance. There is no deployed resolution ingress
adapter merely because the core enqueue boundary is tested. Documentation must state its
absence and show ID-free current-version examples; any future ingress must enforce plan 61.

After Kikan IR-5 publishes the contract/client and pinned fixtures, locate its source with
Mori and verify registry/releases before adoption. Adapt the existing EvidenceReader; do
not widen its scope or fall back to host Git. Exercise exact target/reference/dependency
revisions through production composition, journal the evidence, make the source unavailable
and replay with no reader call. A new workflow may resolve a moved ref; prior evidence
cannot change. Record exact released artifact, configured authority and deployment evidence.

## Concrete Steps

From the repository root capture an implementation baseline and discover the live gate:

```bash
plan46_base=$(git rev-parse HEAD)
mori path mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5
nix develop --no-write-lock-file -c cabal test shikigami-core-test -j1 --test-options='--num-threads=1 -p "practice review"' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-options='--num-threads=1 -p "practice review"' --test-show-details=direct
```

The PostgreSQL suite owns isolated migrated fixtures. Confirm filters select the new
routed/receipt cases, not just pure contracts. Run the migrations smoke/contract suites
if repairs add the association index; verify user documentation through its existing
OKF recipe. At final candidate run full build/serialized applicable suites, scaffold and
the strict workflow gate against the saved baseline. Do not reset any developer database.

```bash
nix develop --no-write-lock-file -c cabal build all
nix develop --no-write-lock-file -c cabal test all -j1 --test-options=--num-threads=1 --test-show-details=direct
nix develop --no-write-lock-file -c just keiro-gate "$plan46_base"
git diff --check
```

## Validation and Acceptance

The original advisory outcome remains the acceptance obligation: real routed specialist,
strict evidence/lineage/profile/identity, five verdicts and four legitimate resolutions,
scoped re-review, correct owner attention, deterministic replay and truthful downstream
receipt handling. M4 additionally needs the already-required review repair acceptance;
M5 needs operator provisioning and exact released live reader proof. No list of historical
passing tests can close an unexercised case. The specialist retains read-only authority.

## Idempotence and Recovery

Use the existing allocation receipt, workflow, memory and sink owners. A lost allocation
reply recovers the committed identity; completed journaled effects are reused; a repeated
resolution command cannot allocate or overwrite a conflicting outcome. Equivalent reviews
retain distinct history and associations with one semantic attention reservation.
Repair failed/dead/unknown delivery through the existing receipt/outbox identity, never
by deleting a reservation. Preserve accepted evidence snapshots when moving to live reads.

## Interfaces and Dependencies

Local predecessors 19/22/24/25/35/40–45/54 are accepted; current scalar/identity/runtime
owners are plans 107/108/124. Repairs 60–63 retain their scopes. Only live content depends
on `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`; generic workspace delivery
does not satisfy that protocol. No dependency upgrade or second model/tool loop is selected.

## Revision Notes

2026-11-06: Replace stale implementation sketches, old test paths, deterministic entity-ID
factories and retired review patch instructions with current code. Correct the overstated
M4/M5 closeout; retain historical results and original decisions, and assign actual missing
safety, provisioning, conformance and live evidence to their existing owners.
