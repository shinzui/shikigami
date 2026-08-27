---
type: Review
title: Practice-review attention reservation
description: The atomic reservation is correct under the concurrent race it was built for, but a replay after a journaled skip can commit a reservation whose outbox message never existed, and the semantic key includes a model-chosen claim id.
generated:
  by: process:claude-code
  at: "2026-08-27T01:04:13Z"
reviewId: REV-2
subject: mori://shinzui/shikigami
subjectKind: component
component: Shikigami.PracticeReview.Attention
reviewedSha: 62861267b8e4994ad15e7083ca0eb6b9a5dc2999
coverage: full
reviewedAt: "2026-08-27T00:12:00Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: high
outcome: changes-requested
dimensions:
  - correctness
  - design
  - test-coverage
  - operability
produced:
  - mori://shinzui/shikigami/plans/60-harden-practice-review-attention-reservation-and-specialist-failure-boundaries
  - mori://shinzui/shikigami/plans/63-extend-practice-review-conformance-to-the-claimed-end-to-end-matrix
context: >-
  Read the complete module, ADR 0035, the sink-intent helpers it calls, and
  the concurrent and real-AgentRun tests that exercise it; traced the
  transaction against keiro's prepareJournalAppend and kiroku's runTransaction
  and condemn semantics in their sources; ran the full suite at the reviewed
  commit. Did not exercise a live Kizashi.
---

# Practice-review attention reservation

## Verdict

Changes requested. The core of the design is right: the semantic message id
is fixed before the transaction, `INSERT ... ON CONFLICT DO NOTHING RETURNING`
under kiroku's read-committed transaction makes the second of two concurrent
writers block and then observe the winner, and the journal append, the
association row, and the winner's outbox and receipt commit together. The
concurrent test proves exactly that race. One ordering inside the transaction
breaks the invariant ADR 0035 exists to guarantee, and one input to the key
weakens cross-run coalescing in a way the tests cannot see.

## Required

1. **Condemn the transaction when the journal already holds the step.**
   `reserveAttention` runs `insertAttentionTx` and `linkAttentionReviewTx`
   before it runs the prepared journal append, and keiro's
   `prepareJournalAppend` performs its `lookupStepResultTx` presence check
   *inside* the returned transaction. On `JournalAlreadyPresent` the code
   returns the stored result without `Tx.condemn`, so the inserts commit. That
   is harmless when the stored result is `Reserved` or `Coalesced`, because
   the row already exists. It is not harmless when the stored result is
   `AttentionSkipped`: a run that journaled a lifecycle skip or grant denial
   through `step`, crashed before completing, and is resumed after the grant
   was added will insert a reservation for a message id that
   `enqueuePreparedSinkIntentTx` never wrote, because the enqueue sits inside
   the `JournalAppended` branch only. Every later equivalent review then
   coalesces onto an outbox message that does not exist, and the ADR's
   "never release a reservation" rule makes the suppression permanent. The
   window is narrow but the invariant is stated as absolute. Either add
   `Tx.condemn` to the `JournalAlreadyPresent` branch, which kiroku documents
   as rolling back while still returning the body's value, or perform the
   presence check before the inserts.
2. **Decide whether `claimId` belongs in the semantic key, and record the
   decision.** `materialClaimProjection` hashes `claimId` alongside kind,
   normalized statement, and evidence ids. In production the claim id is
   chosen by the model in its raw proposal; two equivalent disputes evaluated
   in separate runs coalesce only if the model also labels its claims
   identically. ADR 0035 and the plan describe the key as built from material
   claims and cited content, which a reader takes to mean the claim's
   substance. Either drop the id from the projection or state in the ADR that
   claim labels are part of identity. The frozen vector test cannot catch
   this because its fixture fixes the id.
3. **Test the skip path on the atomic interpreter.** No test drives
   `runPracticeReviewAttentionAtomic` through a lifecycle skip or grant
   denial, and none replays after one. The five-classification matrix uses
   the fixture `attention` callback, so the atomic path is exercised only by
   the incomplete-evidence AgentRun case and the concurrent target-suspect
   case.

## Follow-ups that do not block

- `prepareSinkIntentForRecipientWithMessageId` runs before the journal is
  consulted on every replay, so replay re-reads the directory and grant
  table. Replay-safety holds because `step` and the manual append both return
  the stored value, but the read is wasted work on the hot path and is the
  reason finding 1 is reachable at all.
- `lookupAttentionOutboxTx` can never disagree with `messageId`, because both
  derive from the key; the "unexpected outbox message id" branch is dead.
- `targetProjectOf` takes the first target evidence item's repository, or
  the first applicability project; a verdict citing two repositories keys on
  whichever sorts first. Acceptable while adoptions bind one target.
- Once finding 1 is fixed, the `AttentionSkipped` journal value should still
  be reachable by a repair procedure: today the guide says a reservation is
  never released, and a skipped run leaves no reservation to repair, which is
  the correct state and worth one sentence in the guide.

## Evidence

- `Attention.hs` lines 271-293: `insertAttentionTx` and
  `linkAttentionReviewTx` precede `appendTx`; lines 286-287 return on
  `JournalAlreadyPresent` without condemning; line 284 gates the enqueue on
  `inserted` inside the `JournalAppended` branch only.
- `Attention.hs` line 264 journals the skip through `step` under the same
  `practice-review-attention` name the manual append uses, so the replayed
  lookup finds it.
- `keiro/src/Keiro/Workflow/Journal.hs` lines 61-114: the presence check
  `lookupStepResultTx` is inside the transaction that `prepareJournalAppend`
  returns.
- `kiroku-store/src/Kiroku/Store/Transaction.hs` lines 92-100 document
  read-committed write mode and that `condemn` rolls back while returning the
  body's value.
- `Attention.hs` lines 180-188 include `claimId` in the material-claim
  projection; `PracticeReviewOrchestrationSpec.hs` line 714 fixes the fixture
  id to `claim-complete-orchestration`.
- `PracticeReviewOrchestrationSpec.hs` "concurrent equivalent reviews share
  one reservation, outbox, and receipt" passed at the reviewed commit with
  counts `(1, 2, 1)` and one outbox row; "real AgentRun installs review
  patches, recorded lineage, memory, grants, and atomic attention" passed
  with `(1, 1, 1)`.
- Full serialized suite: 801 tests passed at the reviewed commit (see REV-1).
