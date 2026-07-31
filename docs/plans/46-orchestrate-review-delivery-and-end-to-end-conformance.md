---
id: 46
slug: orchestrate-review-delivery-and-end-to-end-conformance
title: "Orchestrate review delivery and end-to-end conformance"
kind: exec-plan
created_at: 2026-07-26T04:38:47Z
intention: "intention_01kyeb9heqecv8041cmwqwqg3q"
master_plan: "docs/masterplans/9-architecture-practice-review-flow.md"
---

# Orchestrate review delivery and end-to-end conformance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A Mori-addressed ADR or shared-practice change can run through the declared
`architecture-practice-router`, reach `opentelemetry-practice-reviewer`, acquire pinned
evidence, recall prior adjudication, produce a validated five-way verdict, persist it, publish
review history, and direct at most one attention item to the correct owner. A consistent
review records Kawa history and memory but never notifies. A sink failure retries delivery and
never changes the verdict.

The end-to-end proof covers all five classifications, explicit human resolution, reference
re-review, child/session lineage, and replay. Replaying or redelivering equivalent evidence
creates no duplicate child, memory, activity, or signal. Repeated commits with the same
normalized disputed claims reuse one logical attention reservation; changed evidence/claims
may create a new one. The delivered agents have no write, patch, merge, or block capability.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Prerequisites: `docs/plans/43-define-architecture-practice-review-contracts.md`, `docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md`, `docs/plans/45-persist-and-adjudicate-architecture-practice-reviews.md`, `docs/masterplans/8-declarative-router-agents.md`, `docs/plans/16-honest-sink-handlers-real-reiaction-and-honored-declaration-fields.md`, `docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md`, `docs/plans/25-replay-safe-flow-memory-capabilities.md`, `docs/plans/35-delegation-as-a-first-class-declared-capability.md`, `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`, `docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md`, `docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md`, and `docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` have landed; Kikan IR-5 must also be completed for the live evidence path.
- [ ] M1: finalize router/specialist declarations, register both Flows, and add checked step topology.
- [ ] M2: implement replay-safe evidence, recall, verdict, provisional-memory, and resolution paths.
- [ ] M3: publish Kawa review/resolution activities with `mori://` and `activity://` context refs.
- [ ] M3: reserve/coalesce owner attention and map classifications to Kizashi/Danwa behavior.
- [ ] M4: add deterministic content/model/downstream fixtures and all five verdict scenarios.
- [ ] M4: prove replay, redelivery, sink retry, explicit resolution, re-review, and read-only safety.
- [ ] Final: checked DSL/domain harness, migrations, `cabal test all`, and user docs are green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Mori inspection of Kizashi source confirms `CreateSignalReq` has no client idempotency key
  and `handleCreateH` mints a fresh signal id on every POST. Existing plan 19 prevents repeat
  sends of one delivered outbox message but cannot coalesce equivalent reviews from different
  runs. This plan therefore needs a logical attention reservation in Shikigami.
- Kawa already deduplicates on `(source, source_event_id)` and accepts closed `mori://` and
  `activity://` context references. Shikigami's current Kawa client sets context refs to empty,
  so this plan must thread validated review refs into the existing request rather than invent a
  new envelope.
- Kikan IR-5 is the current canonical request for the live revision-pinned
  content-plane and ToolEnv seam used by plans 44 and 46.


## Decision Log

Record every decision made while working on the plan.

- Decision: Register separate router and specialist Flows; the router only selects/delegates,
  while the specialist owns evidence, judgment, memory, and delivery.
  Rationale: This preserves the boundary fixed by Kikan Use Case 006 and keeps a specialist
  from extending its own candidate authority.
  Date: 2026-07-25

- Decision: Reserve owner attention by lineage root plus normalized claim/evidence content,
  independent of run id.
  Rationale: Outbox idempotency protects retries of one run; the request also requires
  coalescing equivalent reviews across repeated commits/runs.
  Date: 2026-07-25

- Decision: Publish one Kawa activity for every completed semantic review before deciding
  whether attention is required, and publish resolution as a second activity.
  Rationale: Consistent outcomes and adjudication are organizational history even when they
  should not interrupt a human.
  Date: 2026-07-25

- Decision: If required evidence is incomplete, construct a validated `unresolved` verdict
  from acquisition problems without invoking the model evaluator.
  Rationale: The model cannot repair missing provenance and must not infer an accusation from
  memory.
  Date: 2026-07-25

- Decision: Gate live conformance on Kikan IR-5.
  Rationale: Kikan's top-level OKF request bundle now gives the content-plane
  and ToolEnv work a stable request identity; orchestration must consume that
  settled contract rather than a deleted nested request path.
  Date: 2026-07-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

`docs/masterplans/8-declarative-router-agents.md` delivers declared, lifecycle-aware,
replay-safe routing. Its child
`docs/plans/40-declare-specialist-expertise-and-router-policy.md` creates minimal
proof manifests at `agents/proof/architecture-practice-router.dhall` and
`agents/proof/opentelemetry-practice-reviewer.dhall`; this plan evolves those fixtures into
the concrete advisory agents without changing their names. The router payload comes from
Mori and contains no specialist. Plan 35's Flow delegation preserves parent/child workflow
and Kioku session lineage.

`shikigami-core/src/Shikigami/Flow.hs` holds the Flow registry and
`shikigami-core/src/Shikigami/Agent/Workflow.hs:runFlowBehavior` installs capability
interpreters. `docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md`
supplies evidence acquisition;
`docs/plans/45-persist-and-adjudicate-architecture-practice-reviews.md` supplies replay-safe
review memory.
The specialist needs an additional evaluator port whose production implementation invokes
the landed structured Shikumi/model program and whose tests return deterministic JSON. Only
validation from `docs/plans/43-define-architecture-practice-review-contracts.md` accepts that
JSON as a verdict.

Sink intents are written transactionally and published asynchronously. Plan 19 adds
`shikigami.sink_deliveries` and actual downstream receipts. Kawa is idempotent by
`source_event_id`; Kizashi is not. An "attention reservation" is a Shikigami row that says a
logical disputed-claim set already has a pending/delivered/unknown signal. It is not the
semantic review record and never changes a verdict.


## Plan of Work

Milestone 1 finalizes declarations and topology. Make the router a Flow with routing policy
from `docs/plans/40-declare-specialist-expertise-and-router-policy.md`, with delegates from
`docs/plans/35-delegation-as-a-first-class-declared-capability.md` containing only the
OpenTelemetry reviewer for the first slice, and
no write-capable sinks. Give the specialist `opentelemetry` expertise and a Flow behavior.
Register `architecture-practice-router` and `opentelemetry-practice-review` in the final Flow
registry. Add every stable review operation to `domain/shikigami.keiro` before runtime code:
router catalog/decision/delegate/await plus specialist target/reference/upstream acquisition,
prior recall, verdict, activity, provisional memory, attention, and resolution. Use stable
labels derived from validated review/resolution ids where repeated per-review operations need
uniqueness; never use list ordinal alone for evidence identity.

Milestone 2 implements orchestration in
`Shikigami.Flow.ArchitecturePracticeRouter` and
`Shikigami.Flow.OpenTelemetryPracticeReview` (under the plan-36 core package). The router
decodes trigger version 1 from
`docs/plans/43-define-architecture-practice-review-contracts.md`, invokes `route` from
`docs/plans/42-execute-replay-safe-typed-routing-and-delegation.md`, delegates the unchanged trigger
to each validated selection, and returns typed child results. The specialist derives
`ReviewId`, recalls prior outcomes through
`docs/plans/45-persist-and-adjudicate-architecture-practice-reviews.md`, and invokes acquisition
from `docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md` through an `Evidence`
effect whose interpreter journals target, reference, and upstream operations separately. A
complete bundle goes to `PracticeReviewEvaluator`; strict validation from
`docs/plans/43-define-architecture-practice-review-contracts.md` checks its JSON. An
incomplete bundle deterministically produces `unresolved`. Record the provisional memory
through `docs/plans/45-persist-and-adjudicate-architecture-practice-reviews.md` after
validation. A separate addressed resolution event decodes a resolution through
`docs/plans/43-define-architecture-practice-review-contracts.md`, calls `resolveReview` from
`docs/plans/45-persist-and-adjudicate-architecture-practice-reviews.md`, and never accepts a
signal acknowledgement as input.

Milestone 3 implements history and attention. Extend the Kawa review-output adapter so a
typed payload supplies validated `ContextRef` values; keep the existing closed schemes and
source-event id dedupe. A review activity uses subject `practice-review/<ReviewId>`, carries
the full typed verdict, and includes `mori://` refs for every project/document plus
`activity://review/<ReviewId>` as the stable logical lineage ref. Resolution publishes a
second activity referring to the first lineage.

For attention, add an additive pg-migrate change through the final migration package from
`docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md`
for `shikigami.practice_review_attention`: `attention_key` primary key, lineage root,
normalized claim-set identity, review id, classification, recipient, status
`pending|delivered|unknown`, optional signal id/activity id, and timestamps. Derive
`AttentionKey` with UUIDv5 over lineage root plus sorted claim kind/normalized statement and
cited evidence content hashes; revision-only changes with identical bytes/claims coalesce,
while changed evidence/claims produce a new key. Reserve with `INSERT ... ON CONFLICT` in the
same transaction that enqueues the attention sink. If a pending/delivered/unknown row already
exists, publish review history but enqueue no second Kizashi signal. Plan 19's publisher
records the returned signal id and final status against both delivery receipt and reservation.

Map classifications exactly: consistent creates no reservation; target-suspect addresses the
target owner; reference-suspect addresses the practice owner; unresolved addresses the triage
or both-owner adjudication path and may open/attach a Danwa conversation; legitimate-exception
addresses only an explicitly configured approver. Construct the runtime `KizashiSignal` from
the validated owner, bounded intent, priority, and context tags. Sink denial/failure remains
an outbox/runtime outcome and does not replace the stored verdict.

Milestone 4 adds `Shikigami.ArchitecturePracticeReviewSpec` to the final integration test
component. Use migrated Postgres, fixture content readers, deterministic evaluator outputs,
and Warp Kawa/Kizashi stubs. Cover target-suspect, reference-suspect, exception, unresolved,
consistent, explicit accepted/rejected/narrowed resolution, changed-reference re-review,
router replay after catalog/evaluator changes, specialist replay, equivalent cross-run
coalescing, changed-claim new attention, and transient/permanent sink outcomes. Assert no
tool/sink/declaration grants a write, merge, or block action. Update `docs/user/writing-agents.md`
and add `docs/user/architecture-practice-reviews.md` with payloads, states, operator evidence,
and recovery.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`.

```bash
sed -n '1,260p' docs/masterplans/8-declarative-router-agents.md
sed -n '1,260p' docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md
sed -n '1,280p' docs/plans/25-replay-safe-flow-memory-capabilities.md
mori registry show shinzui/kawa --full
mori registry show shinzui/kizashi --full
```

Check topology and migration manifests before the full suite:

```bash
nix develop -c cabal run keiro-dsl -- check domain/shikigami.keiro --emit
nix develop -c cabal run keiro-dsl -- diff domain/shikigami.keiro --since HEAD^
nix develop -c cabal build all
nix develop -c cabal test all --test-show-details=direct
```

The focused test transcript must identify all five classifications and counts. For a replayed
target-suspect run the observable counts are one router child, one provisional memory, one
Kawa activity, and one Kizashi POST. For a consistent run they are one memory, one Kawa
activity, and zero Kizashi POSTs.


## Validation and Acceptance

The deterministic acceptance suite proves the ten request outcomes. An OpenTelemetry ADR
routes to the declared reviewer without a specialist in the Mori payload. A target
contradiction yields target-suspect with exact evidence and one target-owner signal. Newer
supported target code against stale guidance yields reference-suspect and one practice-owner
signal. A supported constraint yields a scoped exception. Missing/unpinned evidence yields
unresolved without accusation. Consistent records history/memory and no attention.

Replaying any suspended/completed step leaves child, memory, activity, and notification counts
unchanged. Accepting, rejecting, or narrowing a provisional result records an explicit
resolution, supersedes the active memory, retains the chain, and changes later scoped recall.
A reference revision change can create a new review and supersede the prior conclusion without
editing either repository. Two distinct runs with the same lineage root, normalized claims,
and evidence content hashes produce one attention reservation/POST; changed claim evidence
produces a second. A Kizashi 500 retries without changing verdict; a permanent denial is
visible as delivery failure. The declarations and runtime expose no write/merge/block path.
All Keiro checks, migrations, and `nix develop -c cabal test all` exit zero.


## Idempotence and Recovery

Keiro journals every external/read/model/memory/sink decision under stable labels. Evidence
acquisition from `docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md`
reads immutable RepoRefs after any mutable ref is resolved and recorded. Review memory from
`docs/plans/45-persist-and-adjudicate-architecture-practice-reviews.md` and plan 25 use
deterministic memory ids. Kawa uses deterministic source-event ids. The attention table's
primary key and transactional reservation prevent equivalent runs from enqueueing two
signals; plan 19 guards delivery retry and records unknown crash windows for repair.

The migration is additive and idempotent through
`docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md`.
Rolling back code while retaining
the table is harmless. Never delete an unknown attention row automatically: an operator must
reconcile Kizashi and then mark delivered or explicitly release/retry it. Re-running test
migrations and fixtures is safe. Upstream content/model/sink stubs remain local and
deterministic.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 16, 19, 25, 35, 43-45, 47, and completed MasterPlan 8.
The live end-to-end evidence path also waits for Kikan IR-5 at
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`. Orchestration must reuse the settled
routing/delegation, memory, and terminal sink semantics; it may not add parallel lifecycle or
delivery machinery.


## Interfaces and Dependencies

The orchestration ports and coalescing surface are:

```haskell
data PracticeReviewEvaluator = PracticeReviewEvaluator
  { evaluate :: !(EvidenceBundle -> IO (Either PracticeReviewEvaluationError Value))
  }

data AttentionReservation = AttentionReservation
  { key :: !AttentionKey
  , reviewId :: !ReviewId
  , classification :: !PracticeReviewClassification
  , recipient :: !OwnerRef
  , status :: !AttentionStatus
  , signalId :: !(Maybe Text)
  , activityId :: !(Maybe Text)
  }

attentionKey
  :: ReviewId
  -> NonEmpty EvidenceClaim
  -> AttentionKey

reserveAttention
  :: Pool
  -> AttentionReservation
  -> Transaction AttentionReservationResult

recordAttentionDelivery
  :: Pool
  -> AttentionKey
  -> DeliveryReceipt
  -> IO (Either UsageError ())
```

The exact Flow functions are registered as `FlowDef`s and use the types from
`docs/plans/43-define-architecture-practice-review-contracts.md`,
`docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md`, and
`docs/plans/45-persist-and-adjudicate-architecture-practice-reviews.md` rather than duplicate
DTOs. Hard dependencies are `docs/masterplans/8-declarative-router-agents.md`,
`docs/plans/16-honest-sink-handlers-real-reiaction-and-honored-declaration-fields.md`,
`docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md`,
`docs/plans/25-replay-safe-flow-memory-capabilities.md`,
`docs/plans/35-delegation-as-a-first-class-declared-capability.md`,
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`,
`docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md`,
`docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md`,
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`, and Kikan
C16 plans 25/28/29. Kawa/Kizashi source and current API limitations were verified through
Mori. Any package-bound change during implementation must be verified against the
authoritative registry and upstream tags; the local corpus is API evidence, not release
authority.


## Revision Notes

- 2026-07-30: Repointed the live evidence/conformance gate to Kikan IR-5 and
  its stable OKF concept URI.
