---
id: 9
slug: architecture-practice-review-flow
title: "Architecture-practice review flow"
kind: master-plan
created_at: 2026-07-26T04:38:46Z
intention: "intention_01kyeb9heqecv8041cmwqwqg3q"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T18:24:04Z
      mode: "update"
      note: "Reconciled status and progress during the 2026-09-21 portfolio audit"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T20:49:07Z
      mode: "update"
      note: "Make the unstarted repair plans and live content-plane acceptance explicit in the current snapshot."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-12T14:08:07Z
      mode: "update"
      note: "Audit current source, retained evidence and remaining-work relevance at 8d46662a; retain evidence-backed child statuses."
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

The original work is divided into four behavior-oriented streams; the existing
review repair wave (plans 60–63) is now explicitly registered alongside them.
Those repair plans preserve their original scope and do not duplicate the core streams.
EP-4 retains final integrated/live closeout.

The four core streams are: EP-1 fixes the versioned domain
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
| 1 | Review contracts | docs/plans/43-define-architecture-practice-review-contracts.md | None | None | Complete (2026-08-19) |
| 2 | Revision-pinned evidence seam | docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md | EP-1 | None | Complete (deterministic seam; live reader remains in EP-4 acceptance) |
| 3 | Review memory/adjudication | docs/plans/45-persist-and-adjudicate-architecture-practice-reviews.md | EP-1 | None | Complete (2026-08-20) |
| 4 | Orchestration and full closeout | docs/plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md | EP-1, EP-2, EP-3 | EP-5, EP-6, EP-7, EP-8 | In Progress (M4/M5 repairs and live reader remain) |
| 5 | Attention atomicity, semantics and failure boundaries | docs/plans/60-harden-practice-review-attention-reservation-and-specialist-failure-boundaries.md | None | EP-6 | Not Started |
| 6 | Resolver entitlement and envelope hardening | docs/plans/61-enforce-practice-review-resolver-entitlement-and-harden-the-authorization-envelope.md | None | EP-5 | Not Started |
| 7 | Truthful closeout, profile provisioning and operator guidance | docs/plans/62-make-the-practice-review-closeout-and-operator-documentation-true.md | None | EP-6 | In Progress (M1 documentation accepted; M2/M3 open) |
| 8 | Full routed/profile/delivery/identity conformance | docs/plans/63-extend-practice-review-conformance-to-the-claimed-end-to-end-matrix.md | None | EP-5, EP-6, EP-7 | Not Started |

Statuses are Not Started, In Progress, Complete and Cancelled. The four existing repair
plans are now registered rather than hidden behind EP-4's percentage. No plan was created
or acceptance waived. Hard Deps list start gates only; the mandatory milestone/closeout
gates below also govern completion. Original external package/DSL/provider foundations
are accepted; Kikan IR-5 remains the live-reader acceptance prerequisite.

## Dependency Graph

EP-1 supplies contracts to EP-2/EP-3; all three are Complete. EP-4's delivered
M1–M3 supply the actual Flow/interpreters/receipt behavior used by the repair children.
That accepted artifact permits repair work without requiring EP-4's whole incomplete
closeout. There is no circular whole-child start dependency.

EP-4 cannot complete until EP-5–EP-8 are Complete and its live content-plane/deployment
proof passes. EP-8's semantic-key M5 requires EP-5 M2 acceptance; its final entitlement
regressions consume EP-6's new codec, and its installed-profile case consumes EP-7 M2.
Existing owner fixtures permit earlier test development without claiming those absent
outcomes are accepted. Final operator examples in EP-7 follow EP-6's implemented version,
not a prospective schema. These are milestone/completion gates, not optional suggestions.

The existing local foundations (sink delivery/auth, memory/delegation, recorded identity,
router and workflow specification) have landed. Current scalar/allocated identity owners
are plans 107/108; the local Shikumi adapter is plan 124. Live revision-pinned reading
still requires `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`.
The governed workspace provider is not that content-plane protocol.

## Integration Points

**Contracts and identity.** `shikigami-core/src/Shikigami/PracticeReview.hs` owns
checked trigger/verdict/resolution-request types. IdentityStore/Memory own allocated
review/resolution receipts and retained memory transitions under ADRs 0092/0093.
EP-4–EP-8 consume these owners. ReviewId is not an attention key or caller request key;
no child restores deterministic application entity factories.

**Evidence and evaluation.** EP-2's EvidenceReader validates exact repository/revision,
path, opaque content hash, bounds and provenance. EP-4 journals the bounded EvidenceBundle
and raw evaluator result; incomplete evidence yields Unresolved without a model call.
Live reads still await Kikan IR-5. EP-5 adds stable problem rendering and proposal bounds;
it cannot weaken the abstract reader's content-hash contract into an invented SHA grammar.

**Review memory and authorization.** EP-3 owns provisional/adjudicated content and
cross-workflow convergence. The Flow uses the dedicated journaled practice-memory effects,
not generic remember calls. EP-6 adds resolver entitlement through current ID-free ingress
and the next explicit receipt version; EP-4 reuses admitted receipts and retained verdicts
without live replay authorization. EP-7 documents the actually implemented envelope and
keeps the absent deployed ingress adapter explicit.

**Attention and delivery.** Attention.hs owns semantic reservation/association and atomic
journal/outbox/receipt publication. EP-5 repairs valid-retained-result rollback and claim
semantics. Sink/Delivery owns status/retry/unknown truth; no child creates attention-level
delivery state or releases a reservation to retry. EP-8 owns the joined transport/fault
proof. History is unconditional for completed semantic reviews; attention is conditional
and uses the explicit semantic-owner recipient map.

**Routing/profile/inspection.** The existing router owns catalog/selection/delegation;
EP-4 supplies the reviewer Flow and recorded lineage. EP-7 owns operator profile
provisioning; EP-8 proves both actual declarations, resolved profile and recorded identity
through those real paths. The specialist remains advisory/read-only. Reuse current
operator query/receipt owners rather than inventing a separate review supervisor.


## Progress

2026-11-06: three of eight registered children are Complete. EP-4 is In Progress;
EP-5/EP-6/EP-8 remain Not Started. EP-7's bounded closeout/inventory reconciliation
is accepted in this refresh, while profile provisioning and current operator examples
remain. Explicitly registering existing repairs makes Mina's counts include their work.

The current code has real Flow wiring, allocated identities, ID-free schema-2 ingress,
redacted submission credentials, full-request receipt binding, an ingress queue test and
corrupt-retained-attention recovery. It still lacks valid retained-skip rollback,
label-independent semantic keys, resolver entitlement, profile install/show and the full
coupled conformance matrix. No runtime suite or live content call was rerun here.

## Status and relevance audit — 2026-11-12

At `8d46662a`, the registry still correctly records three Complete children,
two In Progress and three Not Started. The four repair plans are already included;
there is no omitted completed repair to mark off. Source still establishes their
need: [`Attention.hs`](../../shikigami-core/src/Shikigami/PracticeReview/Attention.hs)
includes `claimId` in its version-1 semantic projection and can commit a tentative
reservation/association when `JournalAlreadyPresent` returns a valid retained skip.
[`Authorization.hs`](../../shikigami-core/src/Shikigami/PracticeReview/Authorization.hs)
checks submission authorization but has no verdict-bound resolver entitlement.
The operator parser has no sanctioned-profile install/show commands, and
[`Capability.hs`](../../shikigami-core/src/Shikigami/PracticeReview/Capability.hs)
still supplies an unavailable content reader for deployed review composition.

Plans 60/61's correctness and entitlement repairs remain necessary before claiming
this reviewer safe and complete. Plans 62/63 still own usable provisioning,
truthful examples and joined routing/delivery/identity proof. The completed watchdog
and generic objective tools do not perform this revision-pinned ADR review or its
human adjudication. This is a distinct advisory feature; recommend scheduling full
rollout around an actual architecture-review consumer, after core execution and
service-operation gaps, while retaining its safety gates.

The live-reader gate remains unaccepted locally. Mori navigation and a fresh
owner-document read on 2026-11-12 confirm
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5` remains Proposed
with the content-plane contract unratified. No review runtime suite, external
content call or new acceptance was performed.

## Surprises & Discoveries

The old registry omitted the already-required repair plans and its high checkbox fraction
therefore hid substantial unfinished work. They are now explicit registry children with
unchanged scopes and completion gates. The current source additionally supplies allocated
identity/full-request receipt/redaction/ingress/corruption controls, which obsolete parts
of the August repair instructions but do not close the remaining safety matrix.

The original source snapshot predated dedicated replay-safe Flow memory, typed review
allocation and current domain declarations. Those are now delivered. Old instructions to
add missing memory interpreters or retired patch labels have been replaced by the current
owners and the normative workflow guide.


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

In progress. Plans 43 through 45 are complete, and plan 46 delivered the core workflow, but the
2026-08-27 review corpus found correctness, resolver-entitlement, documentation, and conformance
gaps. Plans 60 through 63 are the required registered closeout wave; plan 62 now has
its documentation-reconciliation milestone accepted, with provisioning/examples open. The live evidence adapter remains
fail-closed pending `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`.


## Revision Notes

- 2026-11-12: Verify the still-missing attention, entitlement, provisioning and live-reader
  outcomes against current source; retain all eight child statuses and assess the feature
  separately from completed watchdog/objective work. No repair milestone was newly accepted.

- 2026-11-06: Register existing repair plans 60–63, distinguish accepted core artifacts from final closeout gates, credit delivered identity/ingress hardening and plan-62 documentation while preserving all missing safety, provisioning, conformance and live-reader acceptance.

- 2026-09-21: Reconciled plans 43 through 45 as Complete and plan 46 as In Progress;
  recorded the open review-driven closeout wave in plans 60 through 63.

- 2026-07-30: Repointed the live content-plane and conformance blocker from
  the removed nested request to Kikan IR-5 and its stable OKF concept URI.
- 2026-07-30: Added external edges to plans 25, 35, 47, MasterPlan 8, and Kikan IR-5;
  separated stub-evidence work from the blocked live content-plane adapter.
