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

A version-1 architecture-practice trigger can enter the already-registered
`architecture-practice-router`, be delegated unchanged to the OpenTelemetry specialist, and
finish as a durable advisory review. The specialist acquires bounded revision-pinned evidence,
recalls earlier adjudication, records exactly one validated provisional verdict, publishes the
review to Kawa, and, only when the verdict requires action, creates one coalesced Kizashi
attention item for the deployment-resolved owner. A separately addressed, ingress-authorized
resolution command updates review memory and publishes its own Kawa activity. Signal
acknowledgement and a self-asserted resolver field are never substitutes for authorization.

The observable result is deliberately asymmetric. Every completed semantic review is history
and memory, including `consistent`. Only `target-suspect`, `reference-suspect`, `unresolved`,
and a `legitimate-exception` whose contract says `ApprovalRequired` request attention. Delivery
failure never rewrites a verdict, and delivery status remains exclusively in
`shikigami.sink_deliveries`.

The end-to-end proof covers all five classifications, all four resolution outcomes, reference
re-review, recorded parent/child lineage, workflow replay, outbox redelivery, and equivalent
attention across distinct runs. Replaying one workflow does not reacquire evidence, call the
model, create memory twice, or enqueue either sink twice. Distinct runs with the same normalized
dispute share one attention reservation but retain separate Kawa review history. The agents have
no workspace write, patch, merge, approval-gate, or repository-block capability.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" versus "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-26) Reconciled this plan with the current repository and replaced the July
      architecture. The real router, review contracts, evidence acquisition, review-memory
      capability, sink receipts, pg-migrate boundary, and recorded-principal work are landed.
- [x] (2026-08-26) Verified current Kawa, Kizashi, Kikan, Shikumi, and Keiro source locations
      through Mori. Kawa supports source-event deduplication and context refs; Kizashi still has
      no request idempotency key; Kikan IR-5 remains proposed.
- [ ] External live prerequisite: complete
      `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5` before claiming live
      content-plane conformance. It does not block the deterministic implementation.
- [x] (2026-08-26) M1: turned the proof reviewer into the registered
      `opentelemetry-practice-review` Flow,
      add its execution context and capabilities, and declare every new static workflow step
      behind the required Keiro patches.
- [x] (2026-08-26) M2: implemented strict trigger/authorized-resolution dispatch, one journaled evidence
      snapshot, replay-safe model evaluation, deterministic incomplete-evidence handling, and
      production review-memory integration.
- [x] (2026-08-26) M3: published typed review/resolution history with Kawa context refs and implemented atomic,
      cross-run Kizashi attention reservation without duplicating delivery state.
- [x] (2026-08-26) M4: completed deterministic end-to-end conformance across five verdicts,
      both legitimate-exception attention branches, four resolution outcomes, reference-change
      re-review, replay, semantic attention coalescing, recorded identity, read-only authority,
      and a real AgentRun specialist execution. The full suite retains delivery retry, unknown
      outcome, and recorded-principal coverage.
- [x] (2026-08-26) Completed the deterministic M5 closeout: published operator/user documentation
      and ADRs, regenerated and checked Keiro facts, passed the additive workflow-evolution gate,
      built every package, and passed the serialized 801-test repository suite.
- [ ] External live portion of M5: after Kikan IR-5, install the live `EvidenceReader` adapter,
      exercise operator provisioning against a deployment, and prove pinned-content replay through
      the released content plane. No released IR-5 adapter revision exists to record yet.


## Surprises & Discoveries

The July plan assumed several components were still absent, but plans 42 through 45 have since
landed them. `Shikigami.Flow` already registers `architecture-practice-router`, and that router
already journals a bounded candidate catalog and decision before batch delegation. Its proof
declaration intentionally includes both `opentelemetry-practice-reviewer` and `code-researcher`;
this plan must not silently narrow the catalog to one child. The specialist declaration is the
remaining stub: it still runs the `noop-summary` Shikumi program rather than a Flow.

`Shikigami.PracticeReview.Evidence.acquireEvidence` now performs the complete bounded acquisition
behind a client-independent `EvidenceReader`. Its result contains redacted bounded text and
citations, not raw blobs, so one validated evidence-snapshot step is a safer durable boundary than
the old plan's separate target/reference/upstream step families. The evidence result types do not
yet have a versioned JSON journal codec; production orchestration must add and test that codec
before installing the capability.

`Shikigami.PracticeReview.Memory` already defines the exact four operations and the patch id
`shikigami-practice-review-memory-v1`, but plan 45 deliberately tested it in isolation. The patch
and its labels are not in `domain/shikigami-agent-run.keiro`, and `runFlowBehavior` does not install
the interpreter. This plan owns those production changes; it must not route review data through
the older generic Flow memory capability.

The router preserves the trigger payload, while the verdict contract requires parent and child
workflow/session lineage. That lineage is present in the recorded `RunJob` and current workflow,
not in the trigger. The specialist therefore needs a narrow read-only execution-context capability;
adding synthetic lineage fields to the delegated payload would violate the routing contract.

`RunJob.identity` is the identity of the agent being run, not the human or service that submitted an
addressed command. A bare `PracticeReviewResolution.resolver` is therefore self-asserted and cannot
satisfy plan 45's requirement that the caller authenticate and authorize the command. The runtime
needs a dedicated enqueue boundary that verifies the caller or approved artifact workflow and
records a versioned authorization receipt beside the resolution before the AgentRun starts.

The sink architecture changed materially. ADR 0022 makes `shikigami.sink_deliveries` the only
delivery truth, so an attention table with its own pending/delivered/unknown status and downstream
signal id would create two authorities. Kizashi still generates a fresh signal id for every POST
and exposes no client idempotency key, as verified in `mori://shinzui/kizashi/repos/kizashi` at
project-relative paths `kizashi-api/src/Kizashi/Api/Signal.hs` and
`kizashi-core/src/Kizashi/Signal/Http.hs` (artifact-level Mori URIs are pending). Cross-run
coalescing must therefore happen atomically before the existing outbox, while retry truth stays in
the receipt table.

Kawa already deduplicates `(source, source_event_id)` and accepts closed `mori://` and
`activity://` context-reference schemes in `mori://shinzui/kawa/packages/kawa-api`.
`Shikigami.Sink.KawaClient.buildEnvelope` currently discards context refs, so this plan extends the
existing adapter instead of introducing another Kawa wire type.

Finally, review owners are semantic `OwnerPrincipal` values such as team names, while Kizashi
expects one concrete `recipient_...` destination. `SubjectOwner` and `AreaOwner` are intentionally
unresolvable today. A versioned, boot-validated owner-set-to-recipient map is required; relying on
the deployment-wide Kizashi fallback would silently notify the wrong person.

The landed verdict validator originally required target/reference citations and cited material
claims for every classification. That made the plan's deterministic `Unresolved` result impossible
when the content plane was unavailable: the result could truthfully describe acquisition problems,
but it could not fabricate the missing citations. Validation now keeps the strict evidence rules
for semantic classifications while allowing only `Unresolved` to carry problem claims without
citations.

The atomic reservation needs the journal result before it can append that result in the same
transaction as the outbox and receipt. The existing sink intent derived its message id from the
workflow step, which differs across runs and made the winning id unknowable until enqueue. A narrow
intent helper now accepts the already-derived semantic message id; all existing callers retain the
old wrapper.

Dhall record completion does not permit overriding only the nested `memory.recordPolicy` field in
an agent manifest. The first serialized full-suite run exposed the partial record as invalid in
three loader paths. Supplying the complete memory record (`scope`, `recallLimit`, and
`recordPolicy`) fixed the declaration; the focused 18-test agent-loader suite and the subsequent
full-suite rerun both pass.


## Decision Log

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

Milestones 1 through 4 and the deterministic closeout are implemented. The specialist is a
registered, profile-constrained Flow; the AgentRun body declares and executes both review patches;
evidence, evaluation, memory, history, authorized resolution, and attention cross fixed replay
boundaries; and one database transaction owns semantic reservation, outbox, receipt, and journal
append. The user and operator contract is documented in
`docs/user/architecture-practice-reviews.md`, with supporting updates to the agent, sink, and
configuration guides and ADRs 0034 and 0035.

The focused practice-review suite passes 44 tests, the Kawa adapter group passes 3 tests, the
agent-loader group passes 18 tests, the migration contract passes 5 tests, and the fresh/apply-again
migration smoke suite passes 2 tests. `nix develop -c cabal build all` passes. The exact serialized
`nix develop -c cabal test all -j1 --test-show-details=direct` run passes all 801 tests: 30
conformance, 29 agent, 15 API, 3 client, 590 core, 2 migration smoke, 5 migration contract, 46
server, and 81 worker tests. `just keiro-scaffold` leaves generated facts unchanged, and
`just keiro-gate 8e0df55` classifies `shikigami-practice-review-memory-v1` and
`shikigami-practice-review-flow-v1` as additive and stored-data replay as neutral.

The only unfinished acceptance is external and remains explicit: live evidence and deployment
provisioning require the still-proposed
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`. Production therefore installs the
documented fail-closed unavailable reader; no host-workspace fallback or live-content claim was
added. The deterministic profile and grants are covered by integration tests and documented
operator commands, but those commands were not run against a real deployment database. There is
no exact released Kikan IR-5 revision/version to record until that prerequisite lands.


## Context and Orientation

The parent coordination document is `docs/masterplans/9-architecture-practice-review-flow.md`.
Its older status and path snapshots are context, not current implementation truth; the completed
child plans and present code named below are authoritative for this execution.

The producer contract and advisory domain vocabulary live in
`shikigami-core/src/Shikigami/PracticeReview.hs`. They define `PracticeReviewTrigger`,
`PracticeReviewVerdict`, `PracticeReviewResolution`, deterministic review/resolution ids, the five
classifications, owner roles, explicit resolution outcomes, evidence citations, and validation.
Reuse those types and validators; do not create orchestration DTOs that can drift.

`shikigami-core/src/Shikigami/PracticeReview/Evidence.hs` provides `EvidenceReader`,
`DependencyPinResolver`, `EvidenceLimits`, `acquireEvidence`, and the bounded `EvidenceBundle`.
`shikigami-core/src/Shikigami/PracticeReview/Memory.hs` provides `PracticeReviewMemory`, recall,
provisional recording, adjudication, chain lookup, four fixed step labels, and
`shikigami-practice-review-memory-v1`. Plans 43, 44, and 45 explain the landed invariants and
fixtures.

`shikigami-core/src/Shikigami/Flow.hs` is the single Flow registry. It already contains
`architecture-practice-router`; `Shikigami.Flow.Routing` already journals
`route-catalog-architecture-practice` and `route-decision-architecture-practice`, and
`Shikigami.Flow.Delegate` uses the governed child-run machinery. The reviewer proof manifest is
`agents/proof/opentelemetry-practice-reviewer.dhall`; change its behavior from
`ShikumiProgram { task = "noop-summary" }` to `Flow { name = "opentelemetry-practice-review" }`.
Set `memory.recordPolicy = Never`, keep declaration `sinks = []`, and declare an exact
`sanctionedProfile` id and version that deployment provisioning also installs. The deterministic
suite uses `sanctioned-review` version `1`; implementation must either provision that same profile
for the proof deployment or update both declaration and fixtures together. These settings prevent
generic post-behavior recording/sink dispatch and provider defaults from bypassing the explicit
review capabilities.

`runFlowBehavior` in `shikigami-core/src/Shikigami/Agent/Workflow.hs` installs Flow capability
interpreters from `AgentRunDeps` and the recorded `RunJob`. The latter now carries an
`AgentIdentity`, parent workflow/session metadata, delegation depth, and lineage. All new review
memory, Kawa, and Kizashi effects must use that recorded identity for lifecycle admission, grants,
memory principals, activity actors, and sink intents, following ADR 0033. A current manifest name
must never replace a recorded principal.

The relevant durable-workflow rules are `docs/workflow-versioning.md` and ADRs
`docs/adr/0001-declare-only-what-the-runtime-executes.md`,
`docs/adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md`,
`docs/adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md`,
`docs/adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md`,
`docs/adr/0028-a-router-catalog-is-a-bounded-snapshot-of-declared-authority.md`,
`docs/adr/0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md`,
`docs/adr/0031-practice-review-adjudication-is-a-logical-memory-transition.md`, and
`docs/adr/0033-recorded-agent-principals-key-durable-state.md`. Because this plan adds steps to
the declared AgentRun body, the domain specification, generated facts, actual patch calls, and
both patch branches must land together and pass `just keiro-gate`.

Sink intent preparation and enqueue live in `shikigami-core/src/Shikigami/Sink/Intent.hs`.
`prepareSinkIntent` checks the recorded principal's lifecycle and grant before creating an outbox
message; `enqueuePreparedSinkIntentTx` writes the outbox message and pending receipt in the caller's
transaction. `shikigami-core/src/Shikigami/Sink/Delivery.hs` and the existing
`shikigami.sink_deliveries` table own retry and downstream delivery truth. Kawa and Kizashi publish
asynchronously; the workflow journals only the enqueue outcome.

The repository's pinned dependency cohort is documented in `docs/dependency-cohort.md`. This plan
does not require new package bounds. If implementation discovers one, first locate the source and
dependents with Mori, then verify the chosen version against the authoritative package registry
and upstream release tags before changing the bound.


## Plan of Work

### Milestone 1: Register the specialist and declare its durable shape

Add `Shikigami.Flow.OpenTelemetryPracticeReview` and one `FlowDef` named
`opentelemetry-practice-review`; leave the existing router implementation and catalog intact.
Change only the specialist proof declaration to select that Flow. Give the Flow a simple lifecycle
diagram showing input dispatch, evidence/recall, verdict or resolution, memory, history, and
conditional attention. Deployment validation must refuse the manifest if the Flow name is absent.

Make profile handling honest for the new model-using Flow. Extend `behaviorEnvForProfile` so any
Flow with a resolved `sanctionedProfile` receives `constrainBehaviorEnv`, while a Flow without a
profile retains today's environment. Give the reviewer an exact profile requirement and provision
the matching immutable profile in integration tests and deployment setup. An absent, mutable,
expired, digest-mismatched, or provider-incompatible profile fails before evidence or model work.

Extend `FlowEffects` with narrow, replay-safe capabilities for review execution context, evidence,
evaluation, review memory, and attention. Execution context is a pure reader installed from the
recorded job and current workflow. The other capabilities put IO only in their interpreters; the
Flow body remains unable to use `IOE`, a raw store, a content client, or a model client.

In `domain/shikigami-agent-run.keiro`, declare the already-implemented review-memory patch
`shikigami-practice-review-memory-v1` with its exact four labels:
`practice-review-remember-provisional`, `practice-review-resolve`, `practice-review-recall`, and
`practice-review-chain`. Add a new `shikigami-practice-review-flow-v1` patch containing the static
`practice-review-evidence`, `practice-review-evaluate`, and `practice-review-attention` steps.
History emissions reuse `runSink`'s already-patched `emit-signal:<label>` family, which remains
outside the DSL because colon-bearing labels are not legal Keiro wire words.

The runtime must execute both patch ids, retain their false branches, and use exactly the labels
declared in the domain. An AgentRun that already journaled the old reviewer declaration continues
the old `noop-summary` behavior. A fresh run records the Flow declaration and both patch choices.
Document that transition in `docs/workflow-versioning.md` only if the existing general rules need
clarification; do not create a special unguarded exception.

Acceptance for this milestone is deployment validation for both manifests, exact generated
workflow facts, a replay test for the old declaration boundary, and a focused test proving the new
Flow has no undeclared world-reaching effect.

### Milestone 2: Orchestrate trigger, evidence, evaluation, memory, and authorized resolution

At the Flow entrance, strictly decode the raw JSON as one trigger or one authorized-resolution
envelope. Reject values that decode as neither or both, including a bare resolution. For a trigger,
validate version 1, locate exactly one adoption whose `PracticeKey` is `opentelemetry`, derive the
`ReviewId`, and require delegated parent workflow and session metadata. Build `ReviewLineage` from
the recorded parent data, current workflow id, current Kioku session, and optional prior review id;
do not mutate the producer payload.

Add a versioned `AuthorizedPracticeReviewResolution` transport record containing the landed raw
resolution plus an immutable authorization receipt: authorization id, authority kind (`human` or
`approved-artifact`), verified subject, canonical source reference, and authorization time. Add a
specialized addressed-enqueue function that accepts only an opaque receipt returned by an injected
`ReviewResolutionAuthorizer`; it checks that the verified subject equals `resolution.resolver`,
that the source and authority kind are allowed, and that the command key is stable before enqueue.
The generic addressed enqueue path must not be able to label a bare resolution as authorized. Once
the verified envelope is recorded in `RunJob`, workflow replay consumes that receipt without
calling the external authorizer again. Treat database/queue writers as the existing trusted runtime
boundary and keep credentials or raw authentication tokens out of the receipt and journal.

Add versioned JSON codecs for the bounded evidence snapshot and its problem/provenance members.
Round-trip them with golden fixtures and reject unknown schema versions. The evidence interpreter
calls `acquireEvidence` once with fixed limits, the configured `EvidenceReader`, the configured
`DependencyPinResolver`, validated trigger/adoption, and relevant validated prior resolutions. It
journals the validated snapshot as `practice-review-evidence`. Replays return that snapshot without
resolving a mutable ref or calling the reader again.

Recall scoped practice-review memory before evaluation. A complete evidence bundle goes through
`PracticeReviewEvaluator`, whose production interpreter uses the already-resolved execution profile
and provider environment. Journal the raw JSON proposal as `practice-review-evaluate`, then derive
the expected id, practice, specialist, lineage, and evidence graph from trusted inputs and run the
landed strict verdict validator. Provider failures, invalid JSON, unexpected evidence, or an invalid
classification/owner combination are operational failures and do not write memory or sinks.

For incomplete evidence, skip `practice-review-evaluate` entirely. Construct a low-confidence
`unresolved` verdict with deterministic material claims and recommended action derived from the
sorted structured `EvidenceProblem` values, select the validated triage or joint-owner role, and
run the same verdict validator. Before Kikan IR-5, the production reader returns
`ContentPlaneUnavailable` for each requested content operation, making this branch explicit and
hermetic rather than consulting ambient Git or relying on model memory.

After validation, call `rememberProvisional` with the prior active memory id when re-review
supersedes an earlier provisional state. Let the landed memory capability derive its deterministic
memory id and enforce one logical transition. Do not also invoke generic Flow `remember` and do not
let AgentRun's generic record policy store the behavior output.

For an authorized resolution input, revalidate receipt/resolver agreement and the resolution's
deterministic identity, load the referenced provisional review through `PracticeReviewMemory`, call
`resolveReview`, and return the resolved memory projection. Support `Accepted`, `Rejected`,
`Narrowed`, and `Superseded`, including their applicability and superseding-review invariants. A
Kizashi signal acknowledgement and a bare resolution are never decoded on this path.

### Milestone 3: Publish history and atomically coalesce attention

Create typed JSON payload builders for review and resolution history. A review activity has subject
`practice-review/<ReviewId>`, verb `practice-review.completed`, the full validated verdict, and
validated context refs for the target, each reference/upstream project, and the stable logical ref
`activity://practice-review/<ReviewId>`. A resolution has verb `practice-review.resolved`, its
validated resolution plus review identity, and the same logical activity ref. On the Kawa wire,
represent these as `ContextRef { scheme = "mori://", ref = "namespace/project/..." }` and
`ContextRef { scheme = "activity://", ref = "practice-review/<id>" }`; do not put the scheme in
`ref`.

Extend `Shikigami.Sink.KawaClient` to parse a top-level `context_refs` array from the Flow-created
payload, accept only Kawa's closed schemes, bound and deduplicate the array, and fail permanently on
malformed refs before making an HTTP request. Preserve the existing `KawaDigest` sink, deterministic
`source_event_id`, subject-id override, and Kawa response receipt. Emit stable labels
`review-history` and `resolution-history`; do not add another envelope type or synchronous Kawa call.

Add boot-validated `practice_review.attention_recipients` configuration. A key is either one exact
semantic owner principal or a canonical sorted joint-owner set; a value must parse as a Kizashi
`recipient_...` id. Reject duplicate canonical keys and invalid recipient ids at startup. At runtime,
derive the semantic owner from the validated verdict: target owner for `TargetSuspect`, practice
owner for `ReferenceSuspect`, triage/joint mapping for `Unresolved`, exception approver only for
`LegitimateException` plus `ApprovalRequired`, and none for `Consistent` or `NoApproval` exception.
Missing mappings are operational failures before a reservation exists.

Define `AttentionKey` as UUIDv5 in a frozen, contract-specific namespace. Its canonical preimage
contains schema version, target project, practice key, classification, recommended owner role,
resolved recipient, normalized recommended action, sorted material claim tuples, and sorted cited
evidence tuples of repository, revision, path, and content hash. Strip/collapse whitespace and apply
only the case normalization already used by the contract; do not normalize opaque repository,
revision, path, or hash values. For incomplete evidence, synthesize the claim tuples from sorted
problem constructors and their normalized fields so unrelated evidence outages do not all collide.
Freeze golden vectors before using the key in a migration or workflow journal.

Append an idempotent pg-migrate file and manifest entry for a logical reservation table shaped like:

```sql
CREATE TABLE IF NOT EXISTS shikigami.practice_review_attention (
  attention_key text PRIMARY KEY,
  schema_version integer NOT NULL,
  target_project text NOT NULL,
  practice_key text NOT NULL,
  classification text NOT NULL,
  owner_role text NOT NULL,
  recipient text NOT NULL,
  originating_review_id text NOT NULL,
  claim_evidence_digest text NOT NULL,
  outbox_message_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS shikigami.practice_review_attention_reviews (
  attention_key text NOT NULL REFERENCES shikigami.practice_review_attention(attention_key),
  review_id text NOT NULL,
  linked_at timestamptz NOT NULL,
  PRIMARY KEY (attention_key, review_id)
);
```

Do not add status, downstream signal id, last error, retry count, or delivered timestamp. Operator
queries join `outbox_message_id` to `shikigami.sink_deliveries`; the receipt's status and detail are
the authoritative delivery state and Kizashi signal id. The association table is semantic audit
lineage, not delivery state: it records every distinct `ReviewId` that coalesced into the same
attention item instead of overwriting the originating review.

Implement `PracticeReviewAttention` as one replay-safe capability. First resolve and validate the
recipient and prepare a Kizashi intent using the recorded reviewer identity, explicit recipient,
stable step name, and typed output containing `subject_id`, `review_id`, `attention_key`, bounded
intent text, and `activity_ref`. Add a narrow explicit-recipient preparation helper in
`Shikigami.Sink.Intent`; retain the existing function as a wrapper for all current callers. A
skipped-lifecycle or denied-grant result is journaled without inserting a reservation or outbox.

For an enqueued candidate, use `prepareJournalAppend` and one store transaction. If the journal
record already exists, return it. Otherwise insert the reservation with `ON CONFLICT DO NOTHING`.
In either case, insert the `(attention_key, review_id)` association idempotently. The winner
enqueues the already-prepared outbox message and pending receipt with
`enqueuePreparedSinkIntentTx`, then appends a journal result containing `Reserved` and the outbox
id. The loser appends `Coalesced` with the winning attention key/outbox id and enqueues nothing.
Any failure rolls the entire transaction back. Once committed, never delete or release a reservation
because delivery is dead or unknown; operators repair/retry the existing receipt/outbox identity.

The Flow inspects the Kawa enqueue result. Only `Enqueued` proceeds to attention; lifecycle skip,
grant denial, or preparation failure returns an operational result after memory and creates no
attention reservation. It does not wait for Kawa delivery, so later Kawa retry/failure remains
independent of the already-enqueued attention intent.

Grant `KawaDigest` and `KizashiSignal` to the reviewer's recorded principal through the existing
operator CLI and verify with `grants list`. The declaration remains sink-free because these are
Flow lifecycle emissions, but both enqueue and publication still enforce lifecycle and grant
checks. Revocation affects external delivery, not the recorded verdict.

### Milestone 4: Prove deterministic end-to-end conformance

Add an architecture-practice review integration group to `shikigami-core-test`, reusing
`fixtures/practice-review` and its content-plane fixtures. Use the real AgentRun workflow, real
router and specialist declarations, migrated Postgres, a counting fixture `EvidenceReader`, a
counting deterministic evaluator, the existing outbox publisher, and Warp Kawa/Kizashi stubs. Avoid
an orchestration-only mock that skips journal, identity, grants, or delivery receipts.

Cover the five valid verdicts. `TargetSuspect` notifies the mapped target owner;
`ReferenceSuspect` notifies the mapped practice owner; `LegitimateException` without approval does
not notify and with required approval notifies the mapped approver; incomplete evidence produces
`Unresolved` without an evaluator call; and `Consistent` records memory/history with no attention.
Assert the exact cited revisions/hashes, lineage, recommended owner/action, provisional memory,
Kawa payload/context refs, reservation row, outbox event, receipt, and downstream request.

Cover authorized resolutions for accepted, rejected, narrowed, and superseded review state. Each
command is idempotent, retains the chain, changes subsequent scoped recall according to the landed
memory rules, and publishes exactly one resolution activity. Prove that a bare resolution,
resolver/subject mismatch, disallowed authority, and altered authorization receipt fail before a
memory step; prove replay does not recontact the authorizer. Add a reference-change re-review that
cites the new pinned reference, links the prior review, and leaves both historical verdicts
immutable.

Exercise three identities separately: verified reviewer principal, explicit compatibility identity
with directory disabled, and rejected unresolved legacy identity. Prove memory actors, grant checks,
Kawa actors, and Kizashi sink intents all use the identity recorded in `RunJob`, even if the current
manifest changes between execution and replay.

Replay a run after changing the fixture reader and evaluator; their call counts remain zero and the
journaled result is byte-identical. Redeliver a Kawa intent and observe one canonical activity via
`source_event_id`. Return transient Kizashi 500 responses and prove retry retains one outbox/receipt
identity; exercise terminal 4xx and unknown crash-window handling without creating another
reservation. Run two distinct triggers with equivalent normalized claims/evidence and observe two
Kawa review activities, two attention-review associations, one attention reservation, and one
Kizashi POST. Change one material claim, cited content hash, classification, owner mapping, or
action and observe a new attention key.

Inspect the Flow effect row, declarations, and capability overlays in the tests. They must expose no
workspace writer, raw store/IO, patch/merge action, repository mutation, or blocking authority.
Router results are advisory child outputs; no verdict can stop a build or merge in this plan.

### Milestone 5: Install live evidence and finish operational acceptance

After Kikan IR-5 is implemented, use Mori to locate its released content-plane and ToolEnv source,
verify the released versions against the authoritative registry and upstream tags, and implement the
small adapter to the existing `EvidenceReader` methods. Do not alter the domain contract to match an
incidental client, and do not add ambient filesystem/Git fallback. If Kikan exposes provider-neutral
HTTP rather than a Haskell package, keep the HTTP client at the composition boundary and translate
responses into the existing pinned types.

Run a live, read-only conformance fixture against an exact target revision, exact reference
revision, and dependency-selected upstream revision. Record the first journaled evidence snapshot,
then make the source unavailable and replay the workflow; the same verdict must complete without a
content-plane request. Change a mutable ref only before starting a new workflow and prove the new
resolved revision creates new evidence identity without changing the earlier review.

Update `docs/user/writing-agents.md`, `docs/user/sinks.md`, and add
`docs/user/architecture-practice-reviews.md`. Document raw trigger and resolution examples, all five
classifications, the advisory/no-write boundary, memory state, Kawa refs, recipient-map validation,
grant commands, receipt joins, and dead/unknown delivery recovery. State plainly that re-sending an
equivalent review cannot release an existing reservation; repair uses the existing outbox/receipt.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/shikigami`.

Before changing code, refresh the local dependency evidence and confirm the live gate:

```bash
mori registry list
mori registry show shinzui/kikan --full
mori registry docs shinzui/kikan
mori registry show shinzui/kawa --full
mori registry show shinzui/kizashi --full
mori registry show shinzui/shikumi --full
mori path mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5
```

Inspect the implementation boundaries this plan extends:

```bash
sed -n '1,260p' shikigami-core/src/Shikigami/Flow.hs
sed -n '1,260p' shikigami-core/src/Shikigami/PracticeReview.hs
sed -n '1,260p' shikigami-core/src/Shikigami/PracticeReview/Evidence.hs
sed -n '1,260p' shikigami-core/src/Shikigami/PracticeReview/Memory.hs
sed -n '1,220p' docs/workflow-versioning.md
sed -n '1,220p' domain/shikigami-agent-run.keiro
```

After each workflow-shape change, regenerate and inspect before proceeding. Choose the actual merge
base for the branch; do not leave the placeholder in a completion transcript.

```bash
just keiro-scaffold
just keiro-gate <merge-base>
```

Run focused suites as milestones land:

```bash
nix develop -c cabal test shikigami-core-test -j1 --test-options='-p "practice review"' --test-show-details=direct
nix develop -c cabal test shikigami-migrations-test -j1 --test-show-details=direct
nix develop -c cabal test shikigami-migrations-smoke -j1 --test-show-details=direct
```

Exercise operator grants against migrated development Postgres with the configured reviewer
principal:

```bash
nix develop -c cabal run shikigami -- agents sync
nix develop -c cabal run shikigami -- grants grant opentelemetry-practice-reviewer KawaDigest --by operator
nix develop -c cabal run shikigami -- grants grant opentelemetry-practice-reviewer KizashiSignal --by operator
nix develop -c cabal run shikigami -- grants list
```

Finish with the reproducible full verification. The repository has a history of capacity-shaped
parallel test failures, so keep the full suite serialized.

```bash
nix develop -c cabal build all
nix develop -c cabal test all -j1 --test-show-details=direct
just keiro-gate <merge-base>
git diff --check
```

The completion transcript records focused and full test counts, the migration second-pass result,
the `keiro-diff` classification, and the exact Kikan IR-5 revision/version used by the live adapter.


## Validation and Acceptance

The deterministic acceptance path begins with a version-1 trigger that does not name a specialist.
The registered router snapshots the declared multi-candidate catalog, selects the OpenTelemetry
reviewer, delegates the unchanged payload once, and records the child lineage. The specialist
selects one OpenTelemetry adoption, recalls memory, journals one evidence snapshot, and either
journals one evaluator proposal or deterministically constructs `Unresolved` when evidence is
incomplete. Strict contract validation precedes every memory or sink effect.

For each completed review, exactly one provisional review memory and one Kawa intent exist. A
consistent review and a no-approval legitimate exception have no attention reservation. Each
actionable classification has one correctly mapped recipient, one semantic reservation, one outbox
message, one pending receipt, and at most one downstream Kizashi signal. Delivery success updates
only the receipt and stores the downstream id in `detail`; it does not update the verdict or create
a second attention status.

All four explicit resolution outcomes are accepted only through the specialized authorized enqueue
boundary, versioned authorization receipt, and landed resolution contract. They update the one
logical memory transition, preserve the review chain, and publish one Kawa resolution activity.
Bare/self-asserted commands and acknowledging, closing, or retrying a Kizashi signal do not resolve
review memory.

Workflow replay performs no new reader/model/downstream calls and yields the same output. Kawa
redelivery deduplicates by source event id. Kizashi retry reuses one outbox and receipt identity.
Equivalent semantic disputes in separate workflows retain distinct review history but share one
reservation; a changed material input produces a new key. Lifecycle denial, missing grant, invalid
owner map, unavailable provider, invalid model proposal, and terminal sink response remain visible
operational outcomes and never become semantic classifications.

The live acceptance is incomplete until Kikan IR-5 supplies the content-plane/ToolEnv seam and the
adapter proof passes without host-workspace access. Completion also requires the specialist
manifest and Flow registry to validate, both review patches to appear in generated facts and actual
runtime calls, migrations to apply twice, `just keiro-gate <merge-base>` to pass, and
`nix develop -c cabal test all -j1` to exit zero.


## Idempotence and Recovery

The trigger idempotency key continues to identify one router workflow and one `ReviewId`; existing
delegation reservation prevents a duplicate child. `practice-review-evidence` captures all bounded
pinned reads before their result influences evaluation. `practice-review-evaluate` captures the raw
model proposal before validation. The four review-memory operations use their landed deterministic
ids and patch. Stable history labels create deterministic outbox identities inside one run, and
Kawa independently deduplicates the same source event.

Attention has two idempotency scopes. Keiro journal replay protects one workflow. The UUIDv5
`AttentionKey` and primary key protect equivalent disputes across workflows. Reservation, outbox,
pending receipt, and journal append commit together, so there is no state where a committed
reservation suppresses an outbox that never existed. A conflict is a successful `Coalesced` result,
not an error and not a new Kizashi attempt.

The attention migration is additive and idempotent. Retaining its table during a code rollback is
safe. Do not delete or mutate a reservation to retry delivery. For `failed`, `dead`, or `unknown`,
inspect the joined `sink_deliveries` row and use the existing outbox/receipt recovery procedure. If
Kizashi accepted a request before the local acknowledgement was stored, reconcile the downstream
signal and receipt; never generate a second semantic reservation to hide the crash window.

The pre-IR-5 unavailable reader is safe to rerun because its structured problems are journaled.
After installing the live adapter, old journals retain the unavailable snapshot and verdict; only a
new trigger acquires live content. Test fixtures use unique workflow/review ids and transactional or
explicit cleanup helpers already used by core integration tests, so rerunning them does not depend
on deleting production-shaped data.


## Interfaces and Dependencies

The implementation should converge on narrow ports shaped like the following. Names may adjust to
fit existing modules, but the ownership and replay boundaries must not change.

```haskell
data PracticeReviewExecutionContext = PracticeReviewExecutionContext
  { identity :: !AgentIdentity
  , parentWorkflowId :: !WorkflowId
  , parentSessionId :: !SessionId
  , childWorkflowId :: !WorkflowId
  , childSessionId :: !SessionId
  }

data PracticeReviewEvidence = PracticeReviewEvidence
  { acquire ::
      ValidatedPracticeReviewTrigger ->
      PracticeAdoptionBinding ->
      [ValidatedPracticeReviewResolution] ->
      IO EvidenceBundle
  }

data PracticeReviewEvaluator = PracticeReviewEvaluator
  { evaluate ::
      EvidenceBundle ->
      RecalledPracticeReviews ->
      IO (Either PracticeReviewEvaluationError Value)
  }

data AttentionRecipientResolver = AttentionRecipientResolver
  { resolveRecipient ::
      RecommendedOwner ->
      Either AttentionRoutingError RecipientId
  }

data ReviewResolutionAuthorizer = ReviewResolutionAuthorizer
  { authorize ::
      PracticeReviewResolution ->
      ResolutionSubmissionEvidence ->
      IO (Either ResolutionAuthorizationError AuthorizedResolutionReceipt)
  }

data AttentionReservationResult
  = Reserved
      { attentionKey :: !AttentionKey
      , outboxMessageId :: !Text
      }
  | Coalesced
      { attentionKey :: !AttentionKey
      , outboxMessageId :: !Text
      }
  | AttentionSkipped !SinkResult
```

The evidence capability wraps the existing `EvidenceReader` and `DependencyPinResolver`; the
evaluator wraps the existing profile-constrained provider environment; review memory reuses
`Shikigami.PracticeReview.Memory`; attention reuses `Shikigami.Sink.Intent` and the existing Keiro
journal/store transaction. None of these ports gives the Flow raw `IOE`, a store handle, workspace
access, or mutable repository operations.

Hard repository-local prerequisites are
`docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md`,
`docs/plans/35-delegation-as-a-first-class-declared-capability.md`, and plans 40 through 45 in this
directory. Recorded identity comes from
`docs/plans/54-key-durable-agent-state-by-meibo-principal.md`; workflow evolution comes from
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`. Live evidence
additionally depends on
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`. Kawa source/API evidence is owned by
`mori://shinzui/kawa/packages/kawa-api`; Kizashi API evidence is owned by
`mori://shinzui/kizashi/repos/kizashi`; the model runtime is owned by
`mori://shinzui/shikumi/packages/shikumi`. Re-run Mori discovery before implementation because the
local corpus and registered release metadata can change.


## Revision Notes

- 2026-08-26: Implemented milestones 1 through 4 and the deterministic milestone-5 closeout.
  Recorded the 44-test review matrix, real AgentRun proof, atomic cross-run attention conformance,
  authorization and resolution coverage, 801-test serialized repository pass, additive Keiro gate,
  operator/user documentation, and ADRs 0034 and 0035. Left only the live Kikan IR-5 adapter and
  deployment exercise open, without claiming a released adapter revision.

- 2026-08-26: Rewrote the plan against the current implementation. Preserved the landed router,
  replaced the stub specialist with the only new Flow, collapsed evidence acquisition to one
  bounded journal snapshot, assigned model evaluation to the active profile runtime, added the
  missing review-memory and Flow patch topology, and incorporated recorded-principal identity.
  Replaced the duplicated attention delivery state with an atomic logical reservation joined to
  `sink_deliveries`, corrected the cross-run key to exclude `ReviewId`, added explicit semantic-owner
  routing, closed the self-asserted resolution gap with an ingress authorization receipt, and split
  deterministic completion from the Kikan IR-5 live gate.

- 2026-08-26: Reconciled the prerequisite set. Marked completed plan 44 and the static predecessors
  as satisfied, recorded plans 16, 37, and 38 as discharged, and narrowed the remaining live gate
  to Kikan IR-5.

- 2026-07-30: Repointed the live evidence/conformance gate to Kikan IR-5 and its stable OKF concept
  URI.
