---
id: 9
slug: architecture-practice-review-flow
title: "Architecture-practice review flow"
kind: master-plan
created_at: 2026-07-26T04:38:46Z
intention: "intention_01kyeb9heqecv8041cmwqwqg3q"
---

# Architecture-practice review flow

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

After this initiative, a Mori-addressed Architecture Decision Record (ADR) change can enter
the declared `architecture-practice-router`, reach an allow-listed
`opentelemetry-practice-reviewer`, and complete a durable, evidence-bearing review. The
specialist reads the target, shared practice, and upstream evidence at immutable revisions;
returns exactly one of `consistent`, `target-suspect`, `reference-suspect`,
`legitimate-exception`, or `unresolved`; records provisional and adjudicated memory without
rewriting history; publishes a Kawa activity; and emits at most one owner-directed Kizashi
attention item when the verdict requires it. A replay produces no duplicate child run,
memory, activity, or signal.

The first delivery is advisory and read-only. It includes typed trigger, evidence, verdict,
and resolution contracts; revision-pinned evidence acquisition; replay-safe Flow steps;
Kioku supersession; Kawa/Kizashi delivery; two agent declarations; deterministic fixtures;
and explicit resolution handling. It excludes Mori's adoption graph and fan-out, the general
router mechanism owned by `docs/masterplans/8-declarative-router-agents.md`, automatic
patches, merge rejection, policy enforcement, and invention of evidence missing from the
content plane.


## Decomposition Strategy

The work is divided into four behavior-oriented streams. EP-1 fixes the versioned domain
contract so every other stream shares one vocabulary. EP-2 acquires and normalizes pinned
evidence without making a judgment. EP-3 persists provisional findings and explicit human
resolutions with applicability and supersession semantics. EP-4 composes those capabilities
into the routed Flow, publishes activities and attention, and proves the full lifecycle.

EP-2 and EP-3 can proceed in parallel after EP-1 because evidence acquisition and memory
state transitions share types but not implementations. A single plan was rejected because
the request crosses content-plane, model/Flow, memory, sink, and agent-declaration concerns
and would exceed five milestones. A separate fifth sink plan was rejected because delivery
coalescing can only be validated in the same end-to-end workflow that owns deterministic
review lineage.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Define architecture-practice review contracts | docs/plans/43-define-architecture-practice-review-contracts.md | None | cross-MP: plan 47 for package implementation | Not Started |
| 2 | Acquire revision-pinned architecture-practice evidence | docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md | EP-1; cross-MP: plan 47; upstream Kikan IR-5 for live adapter | None | Not Started |
| 3 | Persist and adjudicate architecture-practice reviews | docs/plans/45-persist-and-adjudicate-architecture-practice-reviews.md | EP-1; cross-MP: plans 25 and 47 | None | Not Started |
| 4 | Orchestrate review delivery and end-to-end conformance | docs/plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md | EP-1, EP-2, EP-3; cross-MP: plans 16, 19, 25, 35, 47, and MasterPlan 8; upstream Kikan IR-5 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 comes first because it defines the trigger, provenance, claim, verdict, resolution,
review-id, and applicability types. EP-2 and EP-3 both consume those types and can then run
in parallel. EP-4 waits for all three because it passes EP-2's evidence bundle into the
specialist, sends the resulting EP-1 verdict through EP-3's memory lifecycle, and maps that
same verdict to delivery behavior.

EP-2 has an external hard dependency on the C16 content-plane and Shikumi ToolEnv work
authored by Kikan plans 25, 28, and 29; if those plans are not implemented, only its
deterministic client seam and stub tests can land. EP-3 hard-depends on
`docs/plans/25-replay-safe-flow-memory-capabilities.md` for labeled `recall` and
`rememberWith`, metadata, deterministic ids, and supersession. EP-4 hard-depends on the
completed declarative-router MasterPlan 8 and plan 35's durable Flow delegation. It also
consumes the honest sink/outbox behavior from plans 16 and 19. Mori's Agent action and
practice-adoption fan-out are external trigger producers; fixtures can exercise the
Shikigami boundary before those producers land.


## Integration Points

IP-1 — domain contracts. EP-1 owns the types under
`shikigami-api/src/Shikigami/Api/PracticeReview.hs`, including their JSON versions and strict
validation. EP-2 through EP-4 consume them without defining local lookalikes. Haskell records
use direct strict fields under `DuplicateRecordFields`.

IP-2 — pinned evidence. EP-2 owns `Shikigami.PracticeReview.Evidence` and the normalized
`EvidenceBundle`. Every material excerpt carries `repoId`, full commit `revision`, `path`,
`contentHash`, and fact/inference role. EP-4 may judge only from this bundle; an incomplete
required bundle deterministically becomes `unresolved`.

IP-3 — review lineage. EP-1 defines deterministic `ReviewId` inputs and EP-3 applies them to
memory ids, supersession, and resolution. EP-4 uses the same lineage for workflow step
labels, Kawa idempotency, and attention coalescing; no consumer invents another key.

IP-4 — memory content and tags. EP-3 owns the typed provisional/resolved memory envelope,
state transition rules, and indexed tags for practice, project, applicability, and active
state. EP-4 invokes it through plan 25's labeled Flow operations. Existing Kioku storage is
not migrated for the first slice.

IP-5 — delivery. EP-4 owns mapping verdict classifications to Kawa/Kizashi/Danwa behavior.
It uses the existing sink outbox and preserves the distinction between semantic verdicts and
delivery failures. `consistent` never emits attention; failures remain retryable runtime
failures.

IP-6 — router integration. MasterPlan 8 owns candidate selection and route decisions. EP-4
provides the concrete router/specialist declarations and passes the untouched review trigger
into the specialist child; Mori never names that specialist.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1 M1: Define and round-trip the versioned trigger and revision provenance types.
- [ ] EP-1 M2: Define the five-way verdict, claim evidence, applicability, and resolution types.
- [ ] EP-1 M3: Add deterministic review ids, validators, fixtures, and public API exports.
- [ ] EP-2 M1: Add a fail-closed content-plane evidence client seam and pinned-read validation.
- [ ] EP-2 M2: Collect target, reference, upstream, and prior-adjudication evidence into one bundle.
- [ ] EP-2 M3: Prove hash/provenance preservation and unresolved behavior for missing evidence.
- [ ] EP-3 M1: Encode provisional and resolved review memories with deterministic ids and tags.
- [ ] EP-3 M2: Implement accepted, rejected, narrowed, and superseded transitions.
- [ ] EP-3 M3: Prove replay idempotency, audit retention, scoped recall, and supersession.
- [ ] EP-4 M1: Declare the architecture router and OpenTelemetry specialist and register the Flow.
- [ ] EP-4 M2: Implement the named durable review steps and typed verdict production.
- [ ] EP-4 M3: Publish Kawa history and coalesced owner attention from the verdict.
- [ ] EP-4 M4: Prove all five verdicts, explicit resolution, re-review, replay, and read-only safety end to end.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Kikan Use Case 006 confirms that Mori's `Agent` reaction and the C16 content plane are
  planned rather than deployed. The Shikigami plans therefore need ports and deterministic
  stubs, with live integration explicitly gated on the upstream plans.
- Current Flow memory performs raw IO and generates a new memory id on every call. Plan 25 is
  not optional: implementing review memory before it lands would make replay duplicate or
  change conclusions.
- Existing Kawa and Kizashi sink clients already expose the necessary wire families but use
  general JSON output. The review initiative can remain additive by producing typed JSON at
  the Flow boundary and using the established transactional outbox.
- Kikan's current top-level improvement-request bundle assigns the
  revision-pinned content-plane and ToolEnv work to IR-5. The child plans now
  use its stable OKF concept URI.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Keep plan 43 startable as contract design, make plan 47 the package-build
  foundation, and gate only live evidence/conformance on Kikan IR-5.
  Rationale: deterministic reader seams and fixtures are valuable independent work, while
  production evidence must use the owned full-SHA content plane rather than ambient Git.
  Date: 2026-07-30

- Decision: Decompose the initiative into contracts, evidence, adjudicated memory, and
  orchestration/delivery.
  Rationale: Each stream creates an independently testable behavior and the ordering keeps
  content-plane, memory, and sink risks separate while sharing one contract.
  Date: 2026-07-25

- Decision: Keep `ReviewId` as the common idempotency and supersession lineage across
  workflows, memory, activity, and attention.
  Rationale: Independent keys would make coalescing and replay proofs ambiguous and could
  suppress or duplicate the wrong review.
  Date: 2026-07-25

- Decision: Make missing, unpinned, hash-mismatched, or version-incompatible required
  evidence yield `unresolved` before model judgment.
  Rationale: The request forbids accusations based on model memory or unversioned excerpts;
  fail-closed evidence validation is part of the semantic contract.
  Date: 2026-07-25

- Decision: Keep sink failures outside `PracticeReviewVerdict`.
  Rationale: Delivery retry state is operational and must not rewrite a completed semantic
  conclusion.
  Date: 2026-07-25


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)


## Revision Notes

- 2026-07-30: Repointed the live content-plane and conformance blocker from
  the removed nested request to Kikan IR-5 and its stable OKF concept URI.
- 2026-07-30: Added external edges to plans 25, 35, 47, MasterPlan 8, and Kikan IR-5;
  separated stub-evidence work from the blocked live content-plane adapter.
