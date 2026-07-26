---
id: 45
slug: persist-and-adjudicate-architecture-practice-reviews
title: "Persist and adjudicate architecture-practice reviews"
kind: exec-plan
created_at: 2026-07-26T04:38:47Z
intention: "intention_01kyeb9heqecv8041cmwqwqg3q"
master_plan: "docs/masterplans/9-architecture-practice-review-flow.md"
---

# Persist and adjudicate architecture-practice reviews

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Every specialist verdict becomes an immutable provisional Kioku memory, and every authorized
human resolution becomes a second immutable memory that supersedes the provisional result.
Accepted and narrowed resolutions guide later reviews only inside their applicability;
rejected findings remain auditable and suppress repetition of the same unsupported claim;
new target/reference revisions create new findings that supersede the prior active conclusion
without deleting history.

The proof records a provisional finding, replays the workflow without duplication, applies
accepted/rejected/narrowed/superseded resolutions, and queries the resulting active view and
full supersession chain. It also proves that a Kizashi acknowledgement cannot call the
resolution function and that competing resolutions produce a visible conflict.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Prerequisites: `docs/plans/43-define-architecture-practice-review-contracts.md` and `docs/plans/25-replay-safe-flow-memory-capabilities.md` have landed.
- [ ] M1: define versioned provisional/resolution memory envelopes, deterministic labels, options, and tags.
- [ ] M1: record one provisional memory idempotently from a validated verdict.
- [ ] M2: apply accepted/rejected/narrowed/superseded resolutions with Kioku supersession.
- [ ] M2: supersede prior active conclusions when material revisions create a new review.
- [ ] M3: recall and decode only applicable active outcomes while retaining rejected/audit context.
- [ ] M3: add real-Postgres replay, scope, chain, and concurrent-resolution tests.
- [ ] Final: no Kioku schema change; `cabal test all` passes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Kioku already records content, confidence, type, tags, session, and `supersedes`, and its
  `record` operation is idempotent by memory id while rejecting a conflicting payload. The
  first slice can therefore remain a Shikigami-owned typed content convention.
- Plan 25's planned `rememberWith` is the critical Flow seam. The current interpreter uses a
  random id and raw IO, so this plan must not ship on the pre-plan-25 implementation.


## Decision Log

Record every decision made while working on the plan.

- Decision: Store typed JSON envelopes in Kioku content and duplicate lookup keys in tags.
  Rationale: Content remains self-describing and auditable, while existing tags support
  bounded filtering without a first-slice schema migration.
  Date: 2026-07-25

- Decision: Record provisional verdicts as `MemoryPattern`; record accepted/narrowed human
  rules as `MemoryConstraint`; record rejected/superseded resolutions as `MemoryFact`.
  Rationale: Accepted/narrowed outcomes constrain later reasoning, while rejection is an
  historical fact rather than a positive rule.
  Date: 2026-07-25

- Decision: Treat the first successful resolution superseding a provisional memory as the
  winner and return a conflict for a different concurrent resolution.
  Rationale: Silently accepting two active truths would make recall nondeterministic; Kioku's
  idempotent/conflict semantics provide a clear boundary.
  Date: 2026-07-25


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The current memory effect lives in
`shikigami-core/src/Shikigami/Flow/Capability.hs`. Plan 25 changes it to labeled Keiro steps
and adds `RememberOptions` with priority, confidence, memory type, tags, and `supersedes`.
It derives deterministic memory ids from workflow identity and the label. This plan builds
domain helpers on that capability; it does not call `Kioku.Memory.record` directly from a Flow.

Mori located Kioku at `/Users/shinzui/Keikaku/bokuno/kioku`. Its
`kioku-core/src/Kioku/Memory.hs` exposes idempotent `record`, `supersede`, active queries, and
supersession-chain queries. `RecordMemoryData` in
`kioku-core/src/Kioku/Memory/Domain.hs` already has all requested metadata. A memory with a
`supersedes` link retires the older active conclusion according to the plan-25 integration
contract.

"Active" means the latest memory eligible to guide a review, not the only audit row. A
superseded/rejected row remains queryable in the chain. "Applicable" means the current
practice, target repo/path, dependency range, and optional expiry satisfy the resolution's
explicit scope.


## Plan of Work

Milestone 1 creates `Shikigami.PracticeReview.Memory` in the plan-36 core package. Define a
versioned `PracticeReviewMemory` sum with `ProvisionalReview` and `ResolvedReview` envelopes
containing the complete values validated by
`docs/plans/43-define-architecture-practice-review-contracts.md`. Encode with canonical JSON text and reject
unknown versions on decode. Build stable labels from review id and resolution id. Build tags
for `practice:<key>`, `project:<repoId>`, `review:<id>`, `state:provisional|resolved`,
classification/outcome, and normalized applicability keys. `rememberProvisional` calls
plan 25's `rememberWith` with the verdict-derived confidence, `MemoryPattern`, session
linkage, and optional prior active memory in `supersedes`.

Milestone 2 implements `resolveReview`. Require a resolution command validated by
`docs/plans/43-define-architecture-practice-review-contracts.md` carrying
an authorized resolver principal and stable resolution id. Derive the provisional memory id
from the original review label, then call `rememberWith` for the resolution with
`supersedes = Just provisionalMemoryId`. Accepted/narrowed records become high-confidence
`MemoryConstraint`; rejected/superseded records become high-confidence `MemoryFact` and
carry the negative/new-lineage explanation. A new material-revision verdict may supersede the
previous active resolved memory supplied by recall. Do not mutate tags/content on older rows.
Return a typed conflict when an existing deterministic id has different content or another
resolution already won.

Milestone 3 implements `recallPracticeReviews` through plan 25's labeled `recall`. Use a
bounded query containing practice and target identities, decode only recognized typed
content, and sort/filter deterministically. Accepted/narrowed results guide only when
`appliesTo` succeeds. Rejected results are returned in a separate `doNotRepeat` collection
and never treated as a rule. Provisional unresolved results are audit/pending context, not
accepted knowledge. Add real-Postgres tests using the repository migration support: replay
same provisional/resolution, accept, reject, narrow scope, new revision supersession, full
chain retention, outside-scope exclusion, expired re-review condition, malformed legacy
memory ignored with diagnostic, and concurrent conflicting resolutions.
Place the integration cases in
`shikigami-core/test/Shikigami/PracticeReviewMemorySpec.hs` (or the exact plan-36 core
integration test package), use `withShikigamiMigratedDatabase`, and register the module in
the test component.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`.

```bash
mori registry show shinzui/kioku --full
sed -n '230,390p' docs/plans/25-replay-safe-flow-memory-capabilities.md
sed -n '1,220p' /Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/Memory/Domain.hs
```

After plan 25 has landed, verify its exact signatures, then format and test:

```bash
rg -n 'rememberWith|RememberOptions|deterministicFlowMemoryId' shikigami-core/src
nix develop -c fourmolu -i shikigami-core/src/Shikigami/PracticeReview/Memory.hs
nix develop -c cabal test shikigami-core-test --test-options='-p "practice review memory"' --test-show-details=direct
nix develop -c cabal test all --test-show-details=direct
```

The focused transcript must show one provisional row after replay, one active resolution,
the provisional row marked superseded, and a chain containing both ids.


## Validation and Acceptance

Record a reference-suspect verdict twice under the same workflow/label. Kioku must contain one
provisional memory with matching content, session, confidence, tags, and review id. Apply an
accepted resolution twice: both calls return the same memory id, the resolution is the sole
active guiding memory, and the supersession chain contains the provisional and resolution.

Repeat with rejection and narrowing. Rejection appears only in `doNotRepeat`; narrowing
guides a matching path/dependency and not a nonmatching one. A newer target or reference
revision creates a new review memory that supersedes the prior active conclusion without
changing the old content. A second different resolver/outcome racing for the same provisional
review returns a conflict and does not create two active rules. Passing a Kizashi
acknowledgement value fails resolution decoding from
`docs/plans/43-define-architecture-practice-review-contracts.md` before any memory step. Full tests exit
zero and no migration is added.


## Idempotence and Recovery

Plan 25 journals every recall/remember label and derives deterministic memory ids. Kioku also
accepts an identical record by id, covering the crash window between database write and
Keiro step recording. A retry with changed semantic content returns `MemoryConflict` rather
than overwriting. No delete or in-place mutation is used. If a run stops between provisional
and resolution, the provisional remains pending and a later explicit resolution can resume
from its deterministic id. Tests provision isolated migrated Postgres databases and are safe
to repeat.


## Interfaces and Dependencies

The domain helper surface is:

```haskell
data RecalledPracticeReviews = RecalledPracticeReviews
  { guiding :: ![ValidatedPracticeReviewResolution]
  , doNotRepeat :: ![ValidatedPracticeReviewResolution]
  , pending :: ![ValidatedPracticeReviewVerdict]
  , diagnostics :: ![ReviewMemoryDiagnostic]
  }

rememberProvisional
  :: (Memory :> es)
  => Maybe MemoryId
  -> ValidatedPracticeReviewVerdict
  -> Eff es MemoryId

resolveReview
  :: (Memory :> es)
  => MemoryId
  -> ValidatedPracticeReviewResolution
  -> Eff es (Either ReviewResolutionError MemoryId)

recallPracticeReviews
  :: (Memory :> es)
  => ReviewRecallContext
  -> Eff es RecalledPracticeReviews

appliesTo :: Applicability -> ReviewRecallContext -> Bool
```

The hard dependency is `docs/plans/25-replay-safe-flow-memory-capabilities.md`; use its landed
labels/options rather than a duplicate effect. Kioku APIs and behavior were verified through
Mori and its source. The initial slice uses existing Kioku records and introduces no package
bound, schema, direct SQL, or new memory store.
