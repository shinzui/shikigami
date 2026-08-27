---
id: 60
slug: harden-practice-review-attention-reservation-and-specialist-failure-boundaries
title: "Harden practice-review attention reservation and specialist failure boundaries"
kind: exec-plan
created_at: 2026-08-27T00:54:32Z
intention: "intention_01m10bc7hae8trp0ev5mzpvt0d"
---

# Harden practice-review attention reservation and specialist failure boundaries

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The OpenTelemetry practice-review specialist (`opentelemetry-practice-review`, the Flow that
plan 46 landed) reserves one Kizashi attention item per *semantically equivalent* review, so
that ten reviews of the same dispute interrupt an owner once. The review records
[REV-2](../reviews/practice-review-attention-reservation.md),
[REV-5](../reviews/opentelemetry-practice-review-flow.md),
[REV-6](../reviews/practice-review-capability-ports.md), and
[REV-3](../reviews/practice-review-attention-migration.md) found four ways that promise can
quietly fail: a resumed workflow can commit a reservation whose outbox message was never
written, so the owner is never told; the "same dispute" key hashes a label the model picks,
so equivalent disputes may not coalesce; incomplete-evidence claims are rendered with
Haskell's derived `Show`, so a harmless rename re-keys every unresolved dispute; and a
malformed input is retried as if it were a crash before it is finally dead-lettered.

After this plan, an operator can prove each of those is closed. A run that journaled an
attention skip and is resumed after the missing grant is added leaves no reservation row
and no phantom outbox id. Two verdicts that differ only in their claim labels produce the
same attention key. The statement recorded for an evidence problem is stable prose with a
golden test. A bare resolution or a trigger with an unknown field is dead-lettered on its
first attempt with `permanent_workflow_failure` in the worker log, not retried. The
association table gains the index the operator audit query needs.


## Progress

- [ ] M1: journal-first attention transaction and the atomic skip/resume test.
- [ ] M2: semantic key version 2 without claim labels, stable evidence-problem statements,
      refreshed frozen vectors, ADR 0035 amendment.
- [ ] M3: permanent classification of Flow input failures, prior-review scope check,
      bounded evaluator proposal.
- [ ] M4: `review_id` index migration and full verification.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Fix the reservation ordering by condemning the transaction when the journal
  already holds the step, rather than by looking the step up before the inserts.
  Rationale: `Keiro.Workflow.Journal.prepareJournalAppend` performs its presence check
  inside the transaction it returns and does not export the lookup; kiroku documents that
  `Tx.condemn` rolls the transaction back while still returning the body's value, which is
  exactly the shape the existing code already relies on for the refusal branches. One line
  closes the defect without a new keiro export.
  Date: 2026-08-27.

- Decision: Remove `claimId` from the semantic projection and bump the projection's
  `schemaVersion` to 2, keeping the frozen namespace.
  Rationale: ADR 0035 says a projection change is a new version. The claim id is chosen by
  the model in its raw proposal and is not part of the dispute's substance; kind, normalized
  statement, and cited evidence ids are. No production reservation rows exist (ADR 0027:
  Shikigami is pre-release), so no migration of stored keys is needed.
  Date: 2026-08-27.

- Decision: Replace `show problem` with an explicit renderer, `renderEvidenceProblem`, and
  freeze its output with a golden test.
  Rationale: the statement is user-facing in Kawa history and, because incomplete-evidence
  claims are material, it is hashed into the attention key. Derived `Show` changes whenever a
  constructor or field is renamed. An explicit renderer with a golden test makes a wording
  change a deliberate, reviewed key change.
  Date: 2026-08-27.

- Decision: Classify `PracticeReviewFlowFailure` as a permanent agent-run failure at the
  existing `runFlowBehavior` catch site instead of introducing a typed Flow error effect.
  Rationale: `runFlowBehavior` already converts one Flow exception
  (`ApprovalAcknowledgementFailed`) into `Left detail`, which `runSessionedAgent` wraps as
  `PermanentAgentRunFailure` and the worker dead-letters. Extending that `fromException` case
  is the smallest change that gives a deterministic input failure the terminal outcome it
  deserves, and it changes no journal shape.
  Date: 2026-08-27.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami runs each agent execution as a durable keiro workflow named `shikigami.agent-run`
(`shikigami-core/src/Shikigami/Agent/Workflow.hs`). "Durable" means every externally
visible result is written to a journal in PostgreSQL under a step name, and when the
process crashes and the run is resumed, each step returns its journaled value instead of
re-running. A "patch" is keiro's guard that lets a body add steps without confusing runs
that started before the steps existed; the two practice-review patches are declared in
`domain/shikigami-agent-run.keiro` and must not change here.

The specialist Flow is `shikigami-core/src/Shikigami/Flow/OpenTelemetryPracticeReview.hs`.
It reaches the world only through narrow effects declared in
`shikigami-core/src/Shikigami/PracticeReview/Capability.hs`; their production
interpreters are installed in `runFlowBehavior` in `Shikigami/Agent/Workflow.hs`. The
attention effect's production interpreter is `runPracticeReviewAttentionAtomic` in
`shikigami-core/src/Shikigami/PracticeReview/Attention.hs`. It derives an `AttentionKey`
(a UUIDv5 over a canonical JSON projection of the verdict), prepares a Kizashi sink intent
whose outbox message id is `practice-review-attention:<key>`, and then runs one database
transaction that inserts the reservation row, links the review id to the key, appends the
workflow journal result, and, for the winning insert only, writes the outbox message and
its pending delivery receipt. The tables are `shikigami.practice_review_attention` and
`shikigami.practice_review_attention_reviews`, created by
`shikigami-migrations/sql-migrations/2026-08-26-20-30-00-practice-review-attention.sql`.

The defect in M1 is an ordering. `reserveAttention` (Attention.hs lines 226-298) calls
`insertAttentionTx` and `linkAttentionReviewTx` before it runs the transaction returned by
`prepareJournalAppend`. That keiro function (`keiro/src/Keiro/Workflow/Journal.hs`,
`prepareJournalAppend`) checks whether the step is already journaled *inside* the returned
transaction and reports `JournalAlreadyPresent stored`. The `JournalAlreadyPresent` branch
in `reserveAttention` returns the stored value without `Tx.condemn`, so the inserts
commit. When the stored value is `AttentionSkipped`, which the skip branch journals through
keiro's `step` under the same `practice-review-attention` name, a resumed run whose grant
was added in the meantime commits a reservation for an outbox message that was never
written, and every later equivalent review coalesces onto it. kiroku's
`Kiroku.Store.Transaction` documents (in the `runTransaction` haddock) that the body runs at
read-committed isolation and that `Tx.condemn` marks the transaction for rollback while
the call still returns the body's value.

Relevant local ADRs, all under `docs/adr/`:
[0035](../adr/0035-practice-review-attention-reserves-semantics-not-delivery-state.md)
defines the key, the atomic transaction, and the never-release rule; it is amended in M2.
[0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) makes
`shikigami.sink_deliveries` the only delivery truth, which is why the reservation must
never point at a message that was not enqueued.
[0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) is why the fix
lives in the interpreter, not the Flow.
[0027](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) is why the
key version can change without a data migration.
[0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) is why no step
name changes in this plan. No cross-repository ADR applies.


## Plan of Work

### Milestone 1: Journal-first attention transaction

At the end of this milestone the transaction in `reserveAttention` cannot commit a
reservation unless it also appends a fresh `Reserved` or `Coalesced` journal record in the
same transaction, and a test proves the skip-then-resume scenario leaves no row.

In `shikigami-core/src/Shikigami/PracticeReview/Attention.hs`, inside the `runTransaction`
block of `reserveAttention`, change the `JournalAlreadyPresent stored` branch so it calls
`Tx.condemn` before returning `firstText (parseEither Aeson.parseJSON stored)`. The
returned value is unchanged; only the writes are discarded. Add a comment above the branch
stating that the inserts above are speculative until the append succeeds and that a
journaled skip must not leave a row behind.

In `shikigami-core/test/Shikigami/PracticeReviewOrchestrationSpec.hs`, add a test to the
`atomicAttentionTests` group named "a journaled skip followed by a granted resume reserves
nothing". Build the attention environment exactly as `attentionEnv` does but with
`grants = StaticGrants (Map.singleton reviewerAgent (Set.fromList [SKawaDigest]))`, so the
Kizashi grant is missing. Run `runPracticeReviewAttentionAtomic` under `runWorkflowWith`
with workflow id `practice-review-attention-skip-resume` and assert the decoded result is
`AttentionSkipped`. Then run the same workflow id again with the full `attentionEnv`
grants. Assert the result is still `AttentionSkipped`, that `attentionCountsStatement`
returns `(0, 0, 0)`, and that `listOutbox "shinzui/shikigami"` is empty. Before the fix the
second assertion fails with counts `(1, 1, 0)`; after it, the test passes.


### Milestone 2: Semantic key version 2 and stable evidence-problem statements

At the end of this milestone equivalent disputes coalesce regardless of the claim labels a
model chose, the statements recorded for evidence problems are stable prose, and ADR 0035
records both facts.

In `Attention.hs`, change `materialClaimProjection` to omit the `claimId` key, keeping
`kind`, the whitespace-normalized `statement`, and the sorted `evidenceIds`. Change the
`schemaVersion` literal in `attentionProjection` from 1 to 2 in both the hashed object and
the `AttentionProjection` record, so the `schema_version` column records 2. Leave
`attentionNamespace` alone; the version lives in the projection, and the namespace string
already says `v1` about the contract family, not the projection. Update the frozen vector
test "frozen target-suspect vector is stable across whitespace normalization" with the new
UUID, obtained by running the test once and copying the reported value into the assertion,
and add an assertion that changing only the fixture claim's `claimId` yields the same key.
Extend "recipient and material action changes produce distinct attention keys" with three
more variations that must change the key: a different classification, a different claim
statement, and a different cited content hash.

In `shikigami-core/src/Shikigami/PracticeReview/Evidence.hs`, add and export
`renderEvidenceProblem :: EvidenceProblem -> Text`. Write one sentence per constructor
that names the repository, revision, path, and the failure in plain words; for example
`ReadFailed repository revision path (ContentPlaneUnavailable detail) required` renders as
"Reading <path> at <revision> in <repository> failed because the content plane was
unavailable: <detail> (required)". Keep every field that distinguishes two problems in the
rendering so that two different problems cannot render identically. In
`Shikigami/Flow/OpenTelemetryPracticeReview.hs`, change `problemClaims` to use
`renderEvidenceProblem` for `statement` and to sort by the rendered text rather than by
`show`. Add a golden test to `shikigami-core/test/Shikigami/PracticeReviewEvidenceSpec.hs`
that renders one value of every constructor and compares against a checked-in fixture
`fixtures/practice-review/evidence-problems-rendered.json` (a JSON array of strings); the
test fails when a rendering changes, which is the point.

Amend `docs/adr/0035-practice-review-attention-reserves-semantics-not-delivery-state.md`
under Decision: state that material claims enter the key by kind, statement, and evidence
ids and not by label; that the projection is at version 2; and that the transaction
appends the journal result before any reservation write becomes durable. ADRs in this
repository are plain Markdown with no OKF frontmatter (`docs/adr/README.md`); correcting an
ADR's evidence in place is allowed by that README.


### Milestone 3: Specialist failure boundaries

At the end of this milestone a deterministic input failure is dead-lettered on its first
attempt, a producer cannot retire a provisional review outside the trigger's recall scope,
and an oversized model reply is refused before it is journaled.

Export `PracticeReviewFlowFailure (..)` from
`Shikigami/Flow/OpenTelemetryPracticeReview.hs`. In `Shikigami/Agent/Workflow.hs`, in
`runFlowBehavior`, extend the `case fromException err of` after `trySync` so that
`Just (PracticeReviewFlowFailure detail)` also yields `pure (Left detail)`; keep the
existing `ApprovalAcknowledgementFailed` case and the rethrow for everything else. Because
`runSessionedAgent` wraps a Flow's `Left` as `PermanentAgentRunFailure`, and
`Shikigami/Workers/Agent/RunJob/Worker.hs` maps that to `deadOutcome
"permanent_workflow_failure"`, no worker change is needed. Add a test to the
`agentRunSpecialistTests` group: submit a `RunJob` whose `triggerPayload` is a bare
`PracticeReviewResolution` (reuse the resolution built in `replayTests`) and assert
`runAgentRunWorkflow` returns `Right (Completed (Left (PermanentAgentRunFailure detail)))`
with "authorized resolution" in `detail`, and that `loadStepIndex` for that workflow shows
no `practice-review-evidence` step.

In `Shikigami/Flow/OpenTelemetryPracticeReview.hs`, replace `priorActiveMemoryId` with a
check that uses its `RecalledPracticeReviews` argument: when the trigger carries
`priorReviewId`, require that some verdict in `pending` has that `reviewId`; if none does,
fail the Flow with "practice-review trigger names a prior review outside its recall
scope". `pending` holds the provisional verdicts that `recallPracticeReviews` returned for
the same project, path, dependencies, and practice, so a prior review of another target
cannot match. Add a test to `replayTests`: run the reference-change trigger from
`completeOpenTelemetryReferenceChangeTrigger` with a `priorReviewId` that was never
reviewed and assert the run is refused before `rememberProvisional` (no
`practice-review-remember-provisional` step in the index). The existing reference
re-review test in `completeClassificationTests` already covers the accepted path.

In `Shikigami/PracticeReview/Capability.hs`, in `modelPracticeReviewEvaluator`, measure
the UTF-8 length of `responseText` and return `Left` with a bounded detail when it exceeds
`maximumProposalBytes = 262144`; add the constant with a comment that the raw proposal is
journaled verbatim. A unit test in `PracticeReviewOrchestrationSpec.hs` can exercise this
by calling `modelPracticeReviewEvaluator` with a `BehaviorEnv` whose model is the stub
provider used in `AgentWorkflowSpec.hs` (`newBehaviorEnv` plus the `stub-v1` model), or,
if that stub cannot return a chosen body, by factoring the size check into an exported
pure function `boundProposalText :: Text -> Either Text Text` and testing that directly.


### Milestone 4: Index migration and verification

At the end of this milestone the audit query from review id to reservation uses an index,
and every repository gate passes.

Run `just new-migration practice-review-attention-review-index` from the repository root.
Replace the generated body with a single statement:
`CREATE INDEX IF NOT EXISTS practice_review_attention_reviews_review_id_idx ON
shikigami.practice_review_attention_reviews (review_id);` and delete the template's
`SET search_path TO kiroku, pg_catalog;` line, because this table is schema-qualified under
`shikigami`. The recipe appends the filename to
`shikigami-migrations/sql-migrations/manifest`. Add a case to
`shikigami-migrations/test/Main.hs` beside "the practice-review attention migration is
appended without delivery state" asserting the new file is embedded and contains the index
name. Then run the full verification in Concrete Steps and record the transcript in
Outcomes.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami`. Builds and tests must run
inside the Nix development shell because `librdkafka` is only on the linker path there;
the local PostgreSQL cluster must be running (`nix develop -c pg_ctl -D db/db status`
reports "server is running").

Focused suites while working:

```bash
nix develop -c cabal test shikigami-core-test -j1 --test-options='-p "practice review"' --test-show-details=direct
nix develop -c cabal test shikigami-migrations-test -j1 --test-show-details=direct
nix develop -c cabal test shikigami-migrations-smoke -j1 --test-show-details=direct
```

Expected after M1, before any other change, for the new case:

```text
    atomic attention
      concurrent equivalent reviews share one reservation, outbox, and receipt: OK
      a journaled skip followed by a granted resume reserves nothing:           OK
```

Full verification at the end:

```bash
nix develop -c cabal build all
nix develop -c cabal test all -j1 --test-show-details=direct
nix develop -c just keiro-gate <merge-base>
git diff --check
```

`just keiro-gate` must report no `BREAKING` finding; this plan adds no step and no patch,
so the expected `keiro-diff` output contains no practice-review lines at all. Replace
`<merge-base>` with the commit this work branches from (`git merge-base master HEAD`, or
the last commit before the plan's first commit when working on `master`).

Every commit carries the trailers:

```text
ExecPlan: docs/plans/60-harden-practice-review-attention-reservation-and-specialist-failure-boundaries.md
Intention: intention_01m10bc7hae8trp0ev5mzpvt0d
```


## Validation and Acceptance

The skip-then-resume test is the acceptance for M1: with the fix reverted it fails on the
`(0, 0, 0)` count assertion, and with the fix it passes; the concurrent test keeps passing,
proving the winner path still commits its row, outbox message, and receipt together.

For M2, `deriveAttentionKey` on two validated verdicts that differ only in `claimId`
returns the same key, and on verdicts differing in classification, a claim statement, a
cited content hash, a recipient mapping, or the recommended action returns different keys.
The golden rendering fixture exists and the rendering test passes; changing any word in
`renderEvidenceProblem` makes it fail.

For M3, submitting a bare resolution as an AgentRun completes with
`PermanentAgentRunFailure` on the first attempt; the worker log line for such a job reads
`worker.job.dead_lettered` with `reason = permanent_workflow_failure`, which can be observed
by running the worker against the local cluster with `nix develop -c cabal run
shikigami-worker` and enqueuing a bare resolution through `cabal run shikigami --
enqueue-run` if a manual check is wanted. A reference-change trigger naming an unknown
prior review is refused without writing memory.

For M4, `just migrate` on the local cluster applies the new file once, and running it
again reports nothing to apply; the migration smoke suite proves fresh and repeated
application.

The whole plan is accepted when `cabal test all -j1` passes with the new cases included
and `just keiro-gate` passes.


## Idempotence and Recovery

Every code edit is additive or a local rewrite; re-running the test suites is safe. The
new migration is `IF NOT EXISTS`. If the frozen-vector update is done before the
projection change, the test fails with the old value; regenerate the UUID from the test
output after the projection change, never by hand. If the golden fixture is regenerated
accidentally, `git diff` on `fixtures/practice-review/evidence-problems-rendered.json`
shows exactly which sentences changed; restore it unless the change was intended. No step
in this plan touches `domain/` or the generated layer, so `just keiro-scaffold` must show
no diff; if it does, the change was made in the wrong place.


## Interfaces and Dependencies

`Shikigami.PracticeReview.Attention` keeps its exports; `attentionProjection` gains the
version-2 projection and `reserveAttention` gains the condemn branch.
`Shikigami.PracticeReview.Evidence` exports `renderEvidenceProblem :: EvidenceProblem ->
Text`. `Shikigami.Flow.OpenTelemetryPracticeReview` exports
`PracticeReviewFlowFailure (..)`. `Shikigami.PracticeReview.Capability` exports
`boundProposalText :: Text -> Either Text Text` and `maximumProposalBytes :: Int` if the
pure factoring in M3 is used. `Shikigami.Agent.Workflow.runFlowBehavior` recognises the
Flow failure exception. Dependencies are unchanged: keiro (`Keiro.Workflow`,
`Keiro.Workflow.Journal` semantics), kiroku (`Kiroku.Store.Transaction.runTransaction`,
`Hasql.Transaction.condemn`), and pg-migrate through the existing migration manifest. The
review records this plan answers are
[REV-2](../reviews/practice-review-attention-reservation.md),
[REV-3](../reviews/practice-review-attention-migration.md),
[REV-5](../reviews/opentelemetry-practice-review-flow.md), and
[REV-6](../reviews/practice-review-capability-ports.md).
