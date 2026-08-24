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

Every validated specialist verdict becomes one immutable provisional Kioku memory identified by
the review's stable `ReviewId`. An explicit resolution becomes a second immutable memory containing
both the original verdict and the validated resolution, then retires the provisional memory with
Kioku's separate supersession command. Accepted and narrowed resolutions guide later reviews only
inside their applicability. Rejected findings remain auditable and suppress repetition of the same
unsupported claim. A review of materially newer target or reference evidence can retire the prior
active conclusion without deleting any row.

After this change, a Flow can use one review-specific capability to record, resolve, recall, and
inspect a review chain without receiving raw IO, a Kioku environment, or generic store access. The
observable proof uses migrated PostgreSQL: replaying the same provisional or resolution operation
does not duplicate a row; accepted, rejected, narrowed, and superseded outcomes produce the right
active view; an out-of-scope rule is excluded; malformed content becomes a diagnostic; the complete
chain remains readable; and competing resolutions converge on one active winner while returning a
typed conflict to the loser.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-24T13:32:21Z) Prerequisites landed: plans 25, 43, and 47 are complete, and the
      workspace selects released `kioku-api`/`kioku-core` 0.5.0.0.
- [x] (2026-08-24T13:32:21Z) Refresh the July plan against the landed Flow capability, checked
      workflow rules, practice-review contracts, ADR corpus, and Kioku 0.5.0.0 source and release
      tag. The refreshed design is recorded in the 2026-08-24 Revision Note.
- [x] (2026-08-24T13:45:06Z) M1: define and round-trip version-1 provisional/resolved envelopes,
      logical Kioku IDs, review scope, deterministic tags, recall context, applicability,
      diagnostics, and chain entries. The 10 focused pure tests pass.
- [x] (2026-08-24T13:45:06Z) M1 implementation: add deterministic provisional recording and
      optional prior-conclusion retirement through Kioku's context-aware APIs.
- [x] (2026-08-24T14:00:41Z) M1 verification: prove same-workflow, cross-workflow, and legacy-branch
      provisional replay, metadata, semantic-conflict, and prior-retirement behavior against
      migrated PostgreSQL.
- [x] (2026-08-24T14:00:41Z) M2: prove the replay-safe `PracticeReviewMemory` capability and its four static labels in an
      isolated Keiro workflow; leave production `FlowEffects` and AgentRun declarations unchanged
      until plan 46 registers the specialist Flow that actually calls them.
- [x] (2026-08-24T14:00:41Z) M2: apply accepted/rejected/narrowed/superseded resolutions with a separate Kioku retirement,
      clean up a losing concurrent candidate, and return a typed conflict.
- [x] (2026-08-24T14:00:41Z) M3: recall only applicable active outcomes into guiding, do-not-repeat, pending, and retired
      collections while retaining malformed-content diagnostics and the full audit chain.
- [x] (2026-08-24T14:00:41Z) M3: add real-Postgres replay, metadata, scope, chain, revision-supersession,
      malformed-content, wrong-scope, acknowledgement-boundary, and concurrent-resolution tests.
      All 17 focused tests pass.
- [x] (2026-08-24T14:00:41Z) Distill the logical-id, immutable-envelope, and record-then-retire
      boundary into [ADR 0031](../adr/0031-practice-review-adjudication-is-a-logical-memory-transition.md).
- [x] (2026-08-24T14:04:24Z) Final: all nine workspace test suites pass (753 tests); ADR 0031
      follows the corpus's sequential plain-Markdown convention; `git diff --check` passes; and the
      plan range contains no production Flow/AgentRun body, domain, migration, Kioku schema, or
      dependency-bound change.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Kioku 0.5.0.0 already records content, confidence, type, tags, session, and lineage, and its
  `recordWithContext` operation accepts the same semantic payload under one memory id while
  rejecting a changed payload. A Shikigami-owned versioned content convention therefore still
  needs no Kioku schema change. Evidence: Hackage lists 0.5.0.0 as normal, upstream tag
  `v0.5.0.0` resolves to commit `cb5f35e2e97477ad4da16e2f64b9d09a6c1634ad`, and the workspace
  pins both Kioku packages to 0.5.0.0.
- Landed plan 25 deliberately makes `RememberOptions.supersedes` lineage-only. It does not retire
  the target; Kioku requires a distinct `supersedeWithContext` command. The July plan's claim that
  `rememberWith` alone creates one active conclusion was therefore false.
- `deterministicFlowMemoryId` is keyed by workflow name, workflow id, generation, and static step
  label. It makes one workflow replay-safe but cannot make two different resolution workflows
  converge on a review-level identity. Review memories need their own UUIDv5-derived Kioku IDs
  from `ReviewId` and `ResolutionId`.
- A resolution needs the original verdict as well as `PracticeReviewResolution`. The resolution
  contract alone carries outcome and applicability but not the evidence and claims later reviews
  must reuse or avoid repeating. The resolved envelope therefore stores both validated values.
- The landed contract has no expiry field. Applicability can be bounded by project, path,
  dependency, and practice; re-review is driven by explicit revision lineage and
  `ReReviewCondition`, not by an invented clock-based expiry rule.
- [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md) forbids declaring the four
  review-memory step labels before a registered Flow can execute them. No current Flow has a
  validated verdict or resolution to pass to this capability; the specialist Flow is plan 46's
  work. Plan 45 therefore proves the labels in an isolated Keiro workflow and leaves production
  `FlowEffects`, `Shikigami.Agent.Workflow`, and `domain/shikigami-agent-run.keiro` unchanged.
- A supersession race is not represented by one stable Kioku refusal constructor. Depending on
  whether the competing command is observed before command handling or while appending, the loser
  can receive an ordinary memory conflict or a command rejection. The transition therefore rereads
  `supersededBy` after any retirement refusal and classifies a recorded winner as the same typed
  `ResolutionConflict`. Evidence: the migrated-PostgreSQL concurrent test converges with one active
  winner and two retired rows.


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
  winner, retire a losing resolution candidate under that winner, and return a typed conflict
  containing the winner id.
  Rationale: Kioku arbitrates the provisional aggregate atomically, but recording the candidate
  and retiring the provisional are two aggregate commands. Cleaning up the loser before returning
  prevents it from remaining an active rule after the race while preserving its audit row.
  Date: 2026-07-25

- Decision: Replace the July draft's generic-`Memory` helpers with a review-specific
  `PracticeReviewMemory` Flow capability whose interpreter owns the multi-command Kioku transition.
  Rationale: generic `rememberWith` performs one record command, deliberately cannot retire another
  aggregate, and derives workflow-scoped ids. The review transition requires logical ids, a
  record-plus-retire protocol, typed conflict cleanup, exact scope reads, and chain reads. Keeping
  those operations behind one narrow capability preserves the no-IO Flow boundary from
  [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md).
  Date: 2026-08-24

- Decision: Derive provisional memory ids from `ReviewId` and resolved memory ids from
  `ResolutionId` under a frozen Shikigami UUIDv5 namespace.
  Rationale: retries and separate workflow instances representing the same logical command must
  target the same Kioku aggregate. Static Keiro labels remain operation names, not data identities.
  Date: 2026-08-24

- Decision: Store both the validated verdict and validated resolution in a resolved envelope.
  Rationale: later review guidance and rejection suppression need the evidence and claim graph from
  the verdict, while the resolution supplies the human outcome and narrowed applicability.
  Date: 2026-08-24

- Decision: Give the capability four fixed operation names:
  `practice-review-remember-provisional`, `practice-review-resolve`, `practice-review-recall`, and
  `practice-review-chain`, but defer their production AgentRun patch/declaration and `FlowEffects`
  integration to plan 46.
  Rationale: static names obey the checked workflow vocabulary and remain stable as review data
  changes. [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md) forbids declaring them
  while no registered Flow calls them; when plan 46 adds the specialist, [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md)
  requires the entire declared body addition inside a new patch with a real runtime branch.
  Date: 2026-08-24

- Decision: After any Kioku retirement refusal, reread the losing row before classifying the
  failure; if `supersededBy` names a winner, return `ResolutionConflict winner` and retire the local
  candidate beneath it.
  Rationale: Kioku can expose the same concurrent loss through different refusal constructors, but
  its projected lineage is the durable arbitration result. Basing convergence on that state makes
  the transition insensitive to command interleaving while retaining genuine refusals.
  Date: 2026-08-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

The review-memory capability, version-1 envelopes, logical IDs, shared scope, deterministic tags,
record-then-retire transitions, bounded active recall, and immutable chain view are implemented in
`Shikigami.PracticeReview.Memory`. The focused suite has 17 passing tests, including replay through
both patch branches, resolution replay across workflow identities, all four outcomes, prior-review
retirement, malformed and wrong-scope diagnostics, and a real concurrent PostgreSQL race.

Implementation confirmed the refreshed plan's central correction: Kioku lineage and Kioku
retirement are separate facts. Deterministic candidates plus projected-winner rereads make the
two-command transition recoverable without a Shikigami table or migration. Production AgentRun
integration remains deliberately owned by plan 46 because no registered Flow can execute these
operations yet.

The final workspace run passed all nine suites and 753 tests, including 547 core tests, 29 checked
Keiro conformance cases, and the package/migration suites. `git diff --check` passed, and a scoped
diff from the plan's first commit confirmed no changes under the production Flow body,
`Shikigami.Agent.Workflow`, `domain/`, or `shikigami-migrations/`. The repository has no ADR-check
recipe; ADR 0031 was checked directly against `docs/adr/README.md` and is the sequential plain
Markdown successor to ADR 0030. No acceptance gap remains in plan 45; plan 46's explicitly deferred
production integration is follow-on work, not unfinished work in this plan.


## Context and Orientation

The pure review contract is `shikigami-core/src/Shikigami/PracticeReview.hs`. Plan 43 has landed:
it defines `ReviewId`, `ResolutionId`, `Applicability`, `PracticeReviewVerdict`,
`PracticeReviewResolution`, and opaque validated wrappers. A verdict contains pinned evidence,
claims, classification, confidence, re-review condition, and applicability. A resolution contains
the human outcome, resolver, reason, time, optional narrowed applicability, and optional
superseding review. The new persistence module belongs beside it at
`shikigami-core/src/Shikigami/PracticeReview/Memory.hs`; no `shikigami-domain` package exists in the
current seven-package workspace.

The existing generic Flow memory effect is
`shikigami-core/src/Shikigami/Flow/Capability.hs`. It journals `recall` and `rememberWith`, derives a
memory id from workflow identity and a static label, and writes exactly one Kioku aggregate.
[ADR 0015](../adr/0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md)
requires the interpreter to preserve Kioku's domain answer rather than conflating a refusal with a
store failure. Its documentation also states that `RememberOptions.supersedes` records lineage
only. Do not weaken or reinterpret that generic effect. This plan adds a separate capability whose
interpreter can perform the review-specific record/retire protocol while Flow code remains unable
to call IO or Kioku directly, as required by
[ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md).

`shikigami-core/src/Shikigami/Flow.hs` defines `FlowEffects`, the complete effect row available to a
registered Flow. `shikigami-core/src/Shikigami/Agent/Workflow.hs:runFlowBehavior` installs every
interpreter around a Flow body. No current registered Flow has a validated verdict or resolution;
the specialist that will call this capability belongs to plan 46. Therefore this plan does not edit
`FlowEffects`, `Shikigami.Agent.Workflow`, `domain/shikigami-agent-run.keiro`, generated workflow
artifacts, or `docs/workflow-versioning.md`. Doing so now would declare and install an operation the
runtime cannot execute, violating
[ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md). Plan 46 must add the capability,
the four fixed labels, and a real `shikigami-practice-review-memory-v1` patch branch in the same
change, following [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md).
Plan 45 proves replay by running the capability in an isolated test workflow whose active patch set
explicitly contains the future patch id; that journal is test data, not a production declaration.

Mori identifies the dependency package as `mori://shinzui/kioku/packages/kioku-core`;
`mori registry show shinzui/kioku --full`
locates its source at `/Users/shinzui/Keikaku/bokuno/kioku`. The workspace selects released
`kioku-api` and `kioku-core` 0.5.0.0. The authoritative Hackage preferred-version document and
upstream `v0.5.0.0` tag agree. At that tag, `Kioku.Memory.recordWithContext` is idempotent by memory
id and rejects semantic drift, `supersedeWithContext` retires one active row under a winner and
rejects a different later winner, `getActiveRowsByScope` returns exact active rows, and
`getSupersessionChain` walks both lineage directions. `Kioku.Memory.Domain.RecordMemoryData` already
holds session, scope, type, content, priority, confidence, tags, and lineage. Use
`Shikigami.Memory.Access.shikigamiWriteContext` for both record and forget permissions; do not add a
new deprecated unsuffixed Kioku call.

Review memories use a shared entity scope in the existing `shikigami` namespace, keyed by normalized
practice, rather than an agent-private scope. This lets later specialist runs for the same practice
see the same adjudication even when agent declarations evolve. Tags duplicate bounded lookup and
audit identities: version, state, practice, review, optional resolution, classification/outcome,
target repository, path, and dependency. Tags are not the authority for decoding; the versioned
content envelope is.

"Active" means Kioku has not retired the row. "Guiding" is narrower: an active accepted or narrowed
resolved envelope whose applicability matches the current review context. "Do not repeat" is an
active rejected resolution matching the original verdict's applicability; it is audit evidence
against repeating the same unsupported claim, not a positive rule. "Pending" is an applicable
active provisional verdict. "Retired outcome" is an active `superseded` resolution fact, which is
kept separate from guidance and rejection. "Applicable" means every non-empty dimension in
`Applicability` matches: repository identity exactly, practice key exactly, dependency token after
trim/case-fold normalization, and path by normalized segment-boundary prefix. An empty dimension is
a wildcard. The contract has no expiry field, so no time comparison belongs here.

[ADR 0008](../adr/0008-repository-provenance-is-shared-domain-vocabulary.md) owns repository identity
and normalized path semantics; use `RepositoryId` and `RelativePath` rather than local text
lookalikes. `docs/adr/` is an ordinary filesystem ADR corpus, not a profiled OKF bundle according to
`mori show --full`, so any durable decision distilled at completion follows the existing numbered
Markdown convention.


## Plan of Work

### Milestone 1 — freeze the review-memory wire and pure behavior

Create `shikigami-core/src/Shikigami/PracticeReview/Memory.hs`. Define a version-1 envelope sum with
`ProvisionalReview` containing one `ValidatedPracticeReviewVerdict` and `ResolvedReview` containing
both that verdict and one `ValidatedPracticeReviewResolution`. Encode compact deterministic JSON
text with an explicit envelope version and kind; the decoder must validate the nested contract
values again and reject an unknown envelope version or kind. The constructor surface must not let a
decoded invalid verdict or resolution enter a recalled result.

Freeze two UUIDv5 identity functions: `provisionalMemoryId :: ReviewId -> MemoryId` and
`resolvedMemoryId :: ResolutionId -> MemoryId`. Use a module-local namespace derived from
`mori://shinzui/shikigami/contracts/practice-review-memory/v1`, length-prefix identity parts, and
`KindID.decorateKindID`, matching the established ReviewId and Flow-memory precedents. Add pinned
test vectors so a refactor cannot silently orphan persisted memory.

Define `ReviewRecallContext`, `AdjudicatedPracticeReview`, `RecalledPracticeReviews`,
`ReviewMemoryDiagnostic`, `PracticeReviewChainEntry`, `PracticeReviewChain`, and
`ReviewMemoryError`. Implement pure confidence mapping, tags, review scope, envelope codecs, and
`appliesTo`. Map verdict confidence 80–100 to Kioku high, 50–79 to medium, and 0–49 to low.
Provisional rows are `MemoryPattern`. Accepted and narrowed rows are high-confidence
`MemoryConstraint`; rejected and superseded rows are high-confidence `MemoryFact`. Pure tests prove
unknown-version rejection, id vectors, tag determinism, path boundary behavior (`src/Foo` matches
`src/Foo/Bar.hs` but not `src/Foobar.hs`), wildcard dimensions, and project/practice/dependency
exclusion.

At the end of this milestone, the wire and pure state classification exist and are independently
testable, but no Flow has acquired a new external capability yet. Run the focused pure tests and
record their result in Progress.

### Milestone 2 — make record and adjudication replay-safe

Define the dynamic `PracticeReviewMemory` effect and a `PracticeReviewMemoryEnv` holding Kioku's
`AppEnv`, the current `AgentDecl`, and optional `SessionId`. Expose four operations with no
caller-supplied labels: `rememberProvisional`, `resolveReview`, `recallPracticeReviews`, and
`recallPracticeReviewChain`. Its interpreter reads patch
`shikigami-practice-review-memory-v1` once, journals the operations under the four fixed names for a
fresh instance, and performs the same idempotent action directly in the legacy branch. Exercise
both branches in `PracticeReviewMemorySpec` with a dedicated test workflow and explicit run options.
Do not install the effect in production `FlowEffects` or edit the checked AgentRun body in this
plan. Record the exact integration obligation for plan 46 in the module documentation and this
plan's Portfolio Reconciliation section.

`rememberProvisional` records a deterministic provisional row with the current session, shared
practice scope, verdict-derived confidence, `MemoryPattern`, envelope text, tags, and optional
`supersedes = priorActiveMemoryId`. With no prior id, one `recordWithContext` completes the
operation. With a prior id, record the candidate, then call `supersedeWithContext prior candidate`.
If another new review already won, retire this candidate under the recorded winner before returning
a typed conflict. Identical replay succeeds; changed content under the same ReviewId is a conflict.

`resolveReview` loads and decodes the provisional row named by its `MemoryId`, verifies that its
verdict ReviewId equals the resolution ReviewId, constructs the resolved envelope, records the
deterministic resolution candidate, and separately retires the provisional under that candidate.
If a different resolution already retired the provisional, re-read its `supersededBy`, retire the
losing candidate under that winner, and return `ResolutionConflict winner`. Infrastructure failures
remain exceptions from the interpreter; missing/malformed/mismatched memories and Kioku domain
refusals become `ReviewMemoryError`. The caller of this capability must already have authenticated
and authorized the resolution event; plan 46 owns that process boundary. A Kizashi acknowledgement
cannot inhabit `ValidatedPracticeReviewResolution`, and a JSON boundary test proves it fails before
the capability runs.

At the end of this milestone, replay and concurrency converge without mutating old content or tags.
Run the focused PostgreSQL transition tests. `just keiro-gate` is not required because this plan
does not change a production workflow body, declaration, generated artifact, or durable identity.

### Milestone 3 — expose the active view and immutable audit chain

`recallPracticeReviews` reads active rows by the exact shared practice scope, then performs bounded
project/path/dependency/practice filtering in Shikigami. Decode only version-1 envelopes. Sort every
result by logical review id and memory id so database ordering cannot change a journal result.
Accepted/narrowed resolved envelopes enter `guiding` only when their resulting applicability
matches. Rejected envelopes enter `doNotRepeat` only when the original verdict applicability
matches. Applicable provisional envelopes enter `pending`. Superseded resolution facts enter
`retired`. A malformed, unknown-version, wrong-scope, or contract-invalid row never guides; it
produces a diagnostic with memory id and stable code.

`recallPracticeReviewChain` derives the provisional id from `ReviewId`, calls Kioku's full-chain
read, and returns every row in creation/id order with status, linkage ids, decoded envelope when
recognized, and diagnostic when not. It includes inactive rows. This is the operator/audit view and
is separate from active recall.

Add `shikigami-core/test/Shikigami/PracticeReviewMemorySpec.hs`, register it in
`shikigami-core/test/Main.hs` and the Cabal test component, and use
`withShikigamiMigratedDatabase`. Cover provisional replay, metadata, all four resolution outcomes,
resolution replay, rejection separation, narrowed path inclusion/exclusion, new-review retirement,
full-chain retention, malformed content, changed-payload conflict, and two concurrently executed
different resolutions. The race must finish with one active resolution, one retired loser, one
retired provisional, and one typed conflict naming the winner. No migration file is added.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`.

```bash
mori registry show shinzui/kioku --full
mori registry docs shinzui/kioku
git -C /Users/shinzui/Keikaku/bokuno/kioku show v0.5.0.0:kioku-core/src/Kioku/Memory.hs
git -C /Users/shinzui/Keikaku/bokuno/kioku show v0.5.0.0:kioku-core/src/Kioku/Memory/Domain.hs
git -C /Users/shinzui/Keikaku/bokuno/kioku show v0.5.0.0:kioku-core/src/Kioku/Memory/ReadModel.hs
sed -n '1,260p' docs/workflow-versioning.md
sed -n '1,220p' docs/adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md
sed -n '1,220p' docs/adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md
sed -n '1,180p' docs/adr/0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md
```

Implement the pure module and focused tests first. Then add the isolated capability interpreter,
transitions, recall, and integration tests. Leave production Flow and generated workflow artifacts
for plan 46. Format only hand-owned Haskell.

```bash
nix develop -c fourmolu -i shikigami-core/src/Shikigami/PracticeReview/Memory.hs
nix develop -c fourmolu -i shikigami-core/test/Shikigami/PracticeReviewMemorySpec.hs
nix develop -c cabal test shikigami-core-test --test-options='-p "PracticeReviewMemory"' --test-show-details=direct
nix develop -c cabal test all --test-show-details=direct
```

The focused transcript must show one provisional row after replay; one active resolution after
resolution replay; the provisional row marked `superseded`; a chain containing both logical ids;
and, in the race, exactly one active winner plus one retired loser and one typed conflict.


## Validation and Acceptance

Acceptance is behavioral and uses the released Kioku 0.5.0.0 API through migrated PostgreSQL.

First, record one validated reference-suspect verdict twice, including a second workflow execution
with the same ReviewId. Both calls return the pinned provisional memory id. Kioku contains one row
whose content decodes to the same verdict, whose session and practice scope match the environment,
whose confidence/type/tags match the documented mapping, and whose journal contains the fixed
remember step once. Reusing the ReviewId with changed semantic content returns a typed conflict and
does not overwrite the row.

Apply an accepted resolution twice. Both calls return the pinned resolved memory id. The resolution
is the sole active guiding memory for a matching context; the provisional is `superseded`; and the
chain contains both immutable envelopes. Repeat with rejection, narrowing, and superseded.
Rejection appears only in `doNotRepeat`. Narrowing guides `src/Regulated/Adapter.hs` when scoped to
`src/Regulated` and does not guide `src/Public/Adapter.hs`. A superseded resolution appears only in
`retired` and never guides.

Record a newer material-review provisional with the prior active resolution id. The newer row is
active, the prior resolution is retired under it, both contents are unchanged, and the chain
contains the earlier provisional, its resolution, and the new provisional. A malformed or
unknown-version memory in the same practice scope is ignored by guidance and returned as one stable
diagnostic. Passing a Kizashi acknowledgement-shaped JSON value fails
`PracticeReviewResolution`/validated-resolution decoding before any practice-review memory step is
journaled.

Race two different valid resolutions for one provisional from separate executions. Exactly one
candidate retires the provisional and remains active. The losing call returns
`ResolutionConflict` naming that winner and retires its own candidate under the winner before it
returns. Active recall never returns both as guidance, while the chain retains all three rows for
audit.

The focused test exits zero, `cabal test all` exits zero,
`git diff --name-only -- shikigami-core/src/Shikigami/Flow shikigami-core/src/Shikigami/Agent/Workflow.hs domain`
is empty, `git diff --name-only -- shikigami-migrations` is empty, and no new dependency bound is
introduced.


## Idempotence and Recovery

Each logical record uses a deterministic memory id independent of workflow identity. Each capability
operation is also one fixed Keiro step. The step action is at-least-once, so every multi-command
transition is deliberately ordered and retryable: record the deterministic candidate, retire the
prior row under it, and, after a competing-winner conflict, retire the losing candidate under the
winner. Kioku ignores call-time timestamps when comparing an otherwise identical retry, so a crash
after any command converges on replay. A changed semantic payload under the same logical id is a
conflict rather than an overwrite.

No delete, content update, tag update, or schema mutation is used. Kioku's status projection changes
only through its append-only `supersedeWithContext` command. If a run stops after the provisional
record, it remains pending. If it stops after recording a resolution candidate but before retiring
the provisional, replay reuses the candidate and finishes the retirement. If it stops while
cleaning up a race loser, replay observes the same winner and repeats the same idempotent cleanup.
The full chain exposes every intermediate row.

The pre-patch capability branch performs the same deterministic IO without a new step, so the
isolated deploy-simulation test proves the future compatibility behavior before plan 46 installs
it. The patch id, runtime branch, declaration, generated active set, conformance expectation, and
workflow inventory must be added and later retired together by plan 46 according to
`docs/workflow-versioning.md`.

Tests provision isolated migrated PostgreSQL databases and are safe to repeat. A failed Keiro gate
must be fixed by correcting the patch/declaration/runtime agreement; do not waive it or hide a label.
Formatting and scaffolding are deterministic and may be rerun.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 25, 43, and 47, all now complete. It preserves plan 25's generic
memory capability unchanged and adds a narrower sibling capability because review transitions need
review-level ids, exact active/chain reads, and a record-plus-retire protocol. Plan 44 remains the
owner of external evidence acquisition; this plan consumes only already validated verdicts and can
be implemented before plan 44's live adapter. Plan 46 must be refreshed before implementation: its
July advice to derive step labels from review/resolution data conflicts with the landed static-label
workflow rules, and it should consume the four operations delivered here. It also owns adding
`PracticeReviewMemory` to `FlowEffects`, installing the interpreter, declaring the four labels
behind `shikigami-practice-review-memory-v1`, regenerating conformance artifacts, updating the
workflow inventory, and running `just keiro-gate` in the same change that registers the specialist
Flow.


## Interfaces and Dependencies

The public surface in `Shikigami.PracticeReview.Memory` is expected to have this shape. Exact
constructor ordering may follow Fourmolu, but the semantic inputs and results are fixed.

```haskell
data PracticeReviewMemory :: Effect

data PracticeReviewMemoryEnv = PracticeReviewMemoryEnv
  { appEnv :: !AppEnv
  , agent :: !AgentDecl
  , sessionId :: !(Maybe SessionId)
  }

data ReviewRecallContext = ReviewRecallContext
  { project :: !ProjectRef
  , path :: !(Maybe RelativePath)
  , dependencies :: !(Set Text)
  , practice :: !PracticeKey
  }

data AdjudicatedPracticeReview = AdjudicatedPracticeReview
  { verdict :: !ValidatedPracticeReviewVerdict
  , resolution :: !ValidatedPracticeReviewResolution
  }

data RecalledPracticeReviews = RecalledPracticeReviews
  { guiding :: ![AdjudicatedPracticeReview]
  , doNotRepeat :: ![AdjudicatedPracticeReview]
  , pending :: ![ValidatedPracticeReviewVerdict]
  , retired :: ![AdjudicatedPracticeReview]
  , diagnostics :: ![ReviewMemoryDiagnostic]
  }

provisionalMemoryId :: ReviewId -> MemoryId
resolvedMemoryId :: ResolutionId -> MemoryId

rememberProvisional
  :: (PracticeReviewMemory :> es)
  => Maybe MemoryId
  -> ValidatedPracticeReviewVerdict
  -> Eff es (Either ReviewMemoryError MemoryId)

resolveReview
  :: (PracticeReviewMemory :> es)
  => MemoryId
  -> ValidatedPracticeReviewResolution
  -> Eff es (Either ReviewMemoryError MemoryId)

recallPracticeReviews
  :: (PracticeReviewMemory :> es)
  => ReviewRecallContext
  -> Eff es RecalledPracticeReviews

recallPracticeReviewChain
  :: (PracticeReviewMemory :> es)
  => ReviewId
  -> Eff es PracticeReviewChain

appliesTo :: Applicability -> ReviewRecallContext -> Bool

runPracticeReviewMemory
  :: (Workflow :> es, IOE :> es)
  => PracticeReviewMemoryEnv
  -> Eff (PracticeReviewMemory : es) a
  -> Eff es a
```

The code depends only on packages already present in `shikigami-core`: `aeson`, `effectful`,
`generic-lens`, `keiro`, `kioku-api`, `kioku-core`, `kindid`, `text`, `time`, and `uuid`. Do not add a
version bound, schema, direct SQL statement, or new memory store. Use Kioku 0.5.0.0's public
`recordWithContext`, `supersedeWithContext`, `getMemoryRowById`, `getActiveRowsByScope`, and
`getSupersessionChain` surfaces discovered through Mori and verified at upstream tag
`v0.5.0.0`; do not rely on the local Kioku checkout's three post-tag commits.


## Revision Notes

- 2026-08-24: Refreshed the plan before implementation against completed plans 25, 43, and 47,
  released Kioku 0.5.0.0, the current seven-package tree, and the checked workflow/ADR rules. The
  refresh corrects two stale assumptions: `rememberWith.supersedes` records lineage without
  retirement, and Flow-derived memory ids are workflow-scoped rather than review-scoped. It replaces
  the generic-memory helper design with a narrow `PracticeReviewMemory` capability, freezes static
  labels and logical ids, specifies record-plus-retire race cleanup, stores the verdict beside the
  resolution, removes the nonexistent expiry rule, and expands acceptance to the active view and
  full audit chain.
- 2026-08-24: During implementation, applied ADR 0001's declare-only rule and moved production
  `FlowEffects`/AgentRun integration plus the checked patch declaration to plan 46, where the
  specialist Flow that actually executes these operations will land. Plan 45 retains an isolated
  journaled workflow proof and does not broaden the production durable body speculatively.
- 2026-08-24: Completed implementation and validation. Added projected-winner rereads for every
  Kioku retirement refusal after PostgreSQL exposed more than one race-time refusal shape, added
  malformed and wrong-scope diagnostics, and recorded the durable transition boundary in ADR 0031.
  The focused 17-test suite and the full nine-suite, 753-test workspace run pass.
