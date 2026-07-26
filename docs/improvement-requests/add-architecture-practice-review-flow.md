---
title: "Add the architecture-practice review flow"
status: proposed
originator: kikan / Use Case 006
target_repo: shinzui/shikigami
contracts: [use-case-006, C1, C5, C16]
created_at: 2026-07-25
---

# Improvement Request: Add the Architecture-Practice Review Flow

## Status

**Proposed.** This is the first domain flow requested for the declarative router-agent
contract. It is advisory: it may record findings and request attention, but it may not block
a merge or edit a repository.


## Planning Coverage

Tracking intention: `intention_01kyeb9heqecv8041cmwqwqg3q`.

This request is tracked by [MasterPlan 9: Architecture-practice review flow](../masterplans/9-architecture-practice-review-flow.md)
and its child ExecPlans:

- [Plan 43: Define architecture-practice review contracts](../plans/43-define-architecture-practice-review-contracts.md)
- [Plan 44: Acquire revision-pinned architecture-practice evidence](../plans/44-acquire-revision-pinned-architecture-practice-evidence.md)
- [Plan 45: Persist and adjudicate architecture-practice reviews](../plans/45-persist-and-adjudicate-architecture-practice-reviews.md)
- [Plan 46: Orchestrate review delivery and end-to-end conformance](../plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md)


## Context

Kikan Use Case 006 asks an agent to review a changed Architecture Decision Record (ADR)
against registered shared practice and relevant upstream evidence, remember the reviewed
outcome, and notify the owner of whichever artifact likely needs correction.

This cannot be implemented as “lint the ADR against the best-practice document.” Registry
membership proves identity and location, not correctness. A newer ADR may expose stale or
over-broad shared guidance. The review contract must therefore be symmetric and
evidence-bearing.

Shikigami already has most of the substrate or has explicit plans for it:

- durable child-run delegation exists; plan 35 makes it generally declarable from a Flow;
- the Kawa, Kizashi, and Danwa sink shapes exist;
- Flow memory exists; plan 25 makes its reads/writes replay-safe and adds configurable
  priority, confidence, type, tags, and supersession;
- Kikan's C16 plans provide revision-pinned multi-repository content to Shikumi/Shikigami;
- the companion router request adds specialist expertise and a typed route decision.

The missing piece is the concrete, typed review lifecycle that composes those capabilities.


## The Request

Add a declared `architecture-practice-router` and a first specialist,
`opentelemetry-practice-reviewer`, backed by a durable Shikigami Flow. Keep technical
instructions in the behavior/program and retrieve practice knowledge through registered,
revision-pinned references; do not bake the current best-practice prose into the manifest.

### Trigger input

Accept an addressed payload from Mori for either a target ADR change or a reference change.
The input must include:

- trigger kind and stable idempotency key;
- canonical target project, before/after revisions, and changed decision paths;
- practice-adoption bindings: practice keys, registered reference project/document ids,
  claimed scope, mode, and resolved owners;
- for a reference-change trigger, the changed reference project, revision pair, and paths;
- an optional prior review id for an explicit re-review.

It must not accept a Mori-selected specialist. The router resolves candidates from its own
Shikigami declaration.

### Typed verdict

Define one versioned `PracticeReviewVerdict` with exactly these classifications:

| Classification | Meaning | Default action |
|---|---|---|
| `consistent` | The target decision and applicable guidance agree, or the difference is immaterial. | Record history; no notification. |
| `target-suspect` | Evidence indicates the ADR or described implementation is likely incorrect or materially incomplete. | Notify the target owner. |
| `reference-suspect` | Evidence indicates the registered practice guidance is stale, incorrect, or scoped too broadly. | Notify the practice owner; do not tell the target to revert. |
| `legitimate-exception` | A supported local constraint justifies a bounded difference. | Record the scoped exception; notify only if approval is required. |
| `unresolved` | Required evidence is missing or conflicting. | Request adjudication; do not accuse either side. |

Every verdict must carry:

- review id, practice key, specialist agent, and parent/child session lineage;
- target and reference project/revision/path/content-hash provenance;
- upstream evidence identities and versions when used;
- claim-level evidence whose kind is explicitly `fact` or `inference`;
- confidence, routing rationale, recommended owner/action, and re-review condition;
- applicability scope for an exception or adjudicated rule;
- verdict schema version.

A missing required pinned read, incompatible/unresolved version, or unverifiable material
claim yields `unresolved`. It must never be represented as `target-suspect` solely from model
memory or an unversioned excerpt.

### Durable review lifecycle

Implement the Flow as replay-safe named steps:

1. Read the target ADR/diff and relevant target code at the target revision.
2. Read every applicable practice reference at one pinned reference revision.
3. Read relevant registered upstream source/docs at a revision compatible with the target's
   dependency pins.
4. Recall prior **adjudicated** findings and scoped exceptions for the practice and target.
5. Produce and validate the typed verdict.
6. Record a Kawa review activity and a provisional Kioku memory.
7. Emit at most one owner-directed attention item for actionable/unresolved outcomes.
8. On an explicit human resolution, record the resolution and supersede the provisional or
   previously active memory.

Use plan 25's labeled, journaled `recall`/`rememberWith` operations and deterministic memory
ids. Store project/practice/applicability keys in the typed memory content and indexed tags;
use `supersedes` for revision and adjudication lineage. Do not mutate or delete old
findings.

The initial verdict memory has state `provisional`. A separate typed resolution has outcome
`accepted`, `rejected`, `narrowed`, or `superseded`, plus resolver identity, reason,
resolved-at time, and resulting applicability. A Kizashi acknowledgement by itself is not
this resolution. Shikigami must consume an explicit resolution command/event or an approved
artifact change linked to the review.

On recall:

- accepted/narrowed outcomes may guide later reviews only within their applicability;
- a rejected result remains auditable and tells the specialist not to repeat the same claim
  without materially new evidence;
- a newer target/reference revision creates a new finding that supersedes, rather than
  rewrites, the previous active conclusion.

### Attention and activity behavior

Publish the completed review as an agent-produced Kawa Activity Envelope using existing
`mori://` and `activity://` context references. Emit no Kizashi signal for `consistent`.
For the other outcomes, choose the recipient from the verdict:

- `target-suspect` → target owner;
- `reference-suspect` → practice owner;
- `unresolved` → triage/both-owner adjudication path;
- `legitimate-exception` → only the explicitly configured approver, if any.

Coalesce attention by review lineage and normalized disputed-claim set. Repeated commits
that do not change the evidence or claims update the existing review rather than creating
notification spam. A sink delivery failure is a runtime failure/retry, never a semantic
verdict change.


## Dependencies and Ownership

This request depends on:

- `docs/improvement-requests/add-declarative-router-agents.md` and plan 35 for bounded,
  allow-listed specialist selection and delegation;
- `docs/plans/25-replay-safe-flow-memory-capabilities.md` for journaled recall/remember and
  memory metadata/supersession;
- Kikan C16 plans 25, 28, and 29 for revision-pinned content and provenance;
- Mori's existing `Agent` action request plus the companion practice-adoption/re-evaluation
  request for triggers and graph context;
- the existing Shikigami sink work for honest Kawa/Kizashi/Danwa delivery.

No Kioku schema change is requested for the first slice: its current memory record already
supports type, confidence, tags, session linkage, and supersession. Shikigami owns the typed
review content and correct use of those fields.


## Acceptance

Use deterministic fixtures plus pinned local repositories to prove:

1. An OpenTelemetry ADR change routes through `architecture-practice-router` to
   `opentelemetry-practice-reviewer`; the specialist is not named in the Mori payload.
2. A target contradiction produces `target-suspect` with exact target/reference evidence
   and one target-owner signal.
3. A newer supported target integration against stale guidance produces
   `reference-suspect` and one practice-owner signal.
4. A supported local constraint produces a scoped `legitimate-exception` memory.
5. Missing or unpinned required evidence produces `unresolved`, not an accusation.
6. A consistent result records review history and memory but emits no attention signal.
7. Replaying any suspended/completed step creates no duplicate memory, activity, child run,
   or notification.
8. Accepting, rejecting, or narrowing a provisional result records an explicit resolution,
   supersedes the old active memory, retains audit history, and changes later recall as
   specified.
9. A changed reference revision can re-run the prior review and supersede its conclusion
   without editing either repository.
10. The flow has no write/merge/block capability in this delivery.


## Out of Scope Here

- Defining Mori's adoption graph or deciding which reference changes fan out to which
  projects.
- General router-agent mechanics; those belong to the companion router request.
- Treating a registered document as intrinsically authoritative.
- Automatic patches, merge rejection, or enforcement mode.
- Inventing upstream evidence when the required project/version is not available through
  the content plane.


## References

- `kikan:docs/use-cases/006-specialist-review-of-architecture-decisions.md`.
- `docs/improvement-requests/add-declarative-router-agents.md`.
- `docs/plans/25-replay-safe-flow-memory-capabilities.md`.
- `docs/plans/35-delegation-as-a-first-class-declared-capability.md`.
- `kikan:docs/plans/25-author-contract-c16-the-repo-content-plane-and-its-provenance-stamp.md`.
- `kikan:docs/plans/28-author-mori-s-content-plane-revision-pinning-bare-mirrors-and-the-repository-content-api.md`.
- `kikan:docs/plans/29-author-the-content-plane-toolenv-and-ephemeral-worktrees-for-shikumi-and-shikigami.md`.
