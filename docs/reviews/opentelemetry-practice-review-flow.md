---
type: Review
title: OpenTelemetry practice-review specialist Flow
description: The Flow dispatches strictly, replaces every trusted field before validation, and orders memory before history before attention as designed; its failure path is crash-shaped rather than terminal, its problem claims are rendered with derived Show, and a producer-named prior review is retired without a relationship check.
generated:
  by: process:claude-code
  at: "2026-08-27T01:04:13Z"
reviewId: REV-5
subject: mori://shinzui/shikigami
subjectKind: component
component: Shikigami.Flow.OpenTelemetryPracticeReview
reviewedSha: 62861267b8e4994ad15e7083ca0eb6b9a5dc2999
coverage: full
reviewedAt: "2026-08-27T00:12:00Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: high
outcome: commented
dimensions:
  - correctness
  - design
  - test-coverage
produced:
  - mori://shinzui/shikigami/plans/60-harden-practice-review-attention-reservation-and-specialist-failure-boundaries
  - mori://shinzui/shikigami/plans/62-make-the-practice-review-closeout-and-operator-documentation-true
context: >-
  Read the complete Flow, its registration in Shikigami.Flow, the AgentRun
  interpreter wiring in Shikigami.Agent.Workflow, the run-job worker's outcome
  table, keiro's crash and failure sentinels, and the orchestration tests;
  ran the full suite at the reviewed commit. Did not run the Flow against a
  live model or content plane.
---

# OpenTelemetry practice-review specialist Flow

## Verdict

Commented. The body honours the plan's boundaries: input is decoded as
exactly one of a strict trigger or an authorized envelope and refused when it
is neither or both; the evaluator's proposal is overwritten with the derived
review id, practice, specialist, recorded lineage, evidence citations, trusted
owner, and watches before the strict validator sees it; incomplete evidence
never reaches the evaluator; and memory is durable before Kawa history is
enqueued and attention is requested only after an `Enqueued` history result.
The suite proves the classification matrix, replay without repeated external
calls, all four resolution outcomes, and reference re-review. None of the
notes below is a release blocker on its own; together they are worth a pass
before the live evidence adapter lands.

## Notes

1. **Deterministic input errors are treated as crashes.** `failFlow` throws
   an imprecise `PracticeReviewFlowFailure`; `runFlowBehavior` catches only
   `ApprovalAcknowledgementFailed` and rethrows everything else, so a bare
   resolution or a trigger with an unknown field unwinds the AgentRun as a
   crash. Keiro retries a crashed run through its attempt budget before
   writing `WorkflowFailed`, and only then does the worker dead-letter it.
   The outcome is right and the tests accept it, but each retry of a poison
   payload repeats evidence acquisition up to the first journaled step. A
   decode failure is known to be permanent at the moment it is detected and
   could be returned as a `PermanentAgentRunFailure` instead.
2. **`problemClaims` renders `show problem` as the claim statement.** That
   text is user-facing in Kawa history and, because incomplete-evidence
   claims are material, it feeds the attention key. A derived `Show` string
   changes whenever a constructor or field of `EvidenceProblem` is renamed or
   reordered, which would silently re-key every equivalent unresolved
   dispute without a schema-version change. The plan asked for tuples built
   from the problem constructor and its normalized fields.
3. **`priorActiveMemoryId` trusts the producer's `priorReviewId`.** The
   recalled memory is passed in and ignored. A valid but unrelated review id
   retires that review's provisional memory in favour of this verdict; an
   unknown id fails the run, which is the safe direction. Producers are the
   router today, so this is a note about the trust assumption rather than a
   defect, but the parameter's presence suggests the check was intended.
4. **History context refs omit the target when no evidence was acquired.**
   `historyContextRefs` derives project refs from cited evidence, so the
   `unresolved` verdict that every production review yields before Kikan
   IR-5 carries only the `activity://` ref. The user guide says refs point to
   the cited projects, which is accurate; the plan said the target was always
   included.
5. **Context refs use the repository id as the Mori project ref.**
   `repositoryRef` strips a `mori://` prefix from `RepositoryId`, so a
   `repo_...` identifier is sent as a `mori://` ref verbatim. Kawa accepts
   the scheme, but whether `repo_target` resolves as a project is a Kawa
   question the tests do not ask.

## Evidence

- `OpenTelemetryPracticeReview.hs` lines 136-158 (strict dual decode),
  286-316 (trusted-field replacement), 187-219 (ordering), 365-375
  (`show`-derived claims), 377-378 (`priorActiveMemoryId` ignores
  `recalled`), 419-431 (context refs), 451-452 (`failFlow`).
- `Agent/Workflow.hs` lines 844-848: only `ApprovalAcknowledgementFailed`
  becomes a `Left`; other exceptions are rethrown.
  `Workers/Agent/RunJob/Worker.hs` lines 421-430: `Failed` is dead-lettered.
  `keiro/src/Keiro/Workflow.hs` lines 474-480: `WorkflowFailed` is written
  when crash attempts are exhausted.
- `Memory.hs` `retireMemory`: an unknown prior yields `ReviewMemoryNotFound`
  and the run fails.
- `PracticeReviewOrchestrationSpec.hs`: "complete evidence covers every model
  classification and approval attention branch", "incomplete evidence skips
  evaluation and replays every external result", and the resolution loop all
  passed at the reviewed commit; `assertRunRefused` accepts an exception or a
  non-completed outcome for the malformed and bare inputs.
