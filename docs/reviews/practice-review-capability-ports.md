---
type: Review
title: Practice-review capability ports and runtime adapters
description: The five narrow effects keep IO in interpreters and behind fixed journal steps, the recipient map is canonicalized and boot-validated, and the model evaluator reuses the profile-constrained environment; the leftover non-atomic attention interpreter and an unjournaled evaluator failure are the only rough edges.
generated:
  by: process:claude-code
  at: "2026-08-27T00:12:00Z"
reviewId: REV-6
subject: mori://shinzui/shikigami
subjectKind: component
component: Shikigami.PracticeReview.Capability
reviewedSha: 62861267b8e4994ad15e7083ca0eb6b9a5dc2999
coverage: full
reviewedAt: "2026-08-27T00:12:00Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: high
outcome: approved
dimensions:
  - correctness
  - design
  - test-coverage
context: >-
  Read the complete module, its installation in Shikigami.Agent.Workflow and
  the worker composition root, the config surface and its strictness tests,
  and the Flow effect row; ran the full suite at the reviewed commit. Did not
  run the model evaluator against a provider.
---

# Practice-review capability ports and runtime adapters

## Verdict

Approved. `ExecutionContext` is a pure reader built from the recorded job;
`PracticeReviewEvidence`, `PracticeReviewEvaluator`, and
`PracticeReviewAttention` put IO only in their interpreters and, when the
`shikigami-practice-review-flow-v1` patch is active, capture each result under
its declared static step before the Flow can act on it. `FlowEffects` grows by
exactly these effects, so no registered Flow gains `IOE`, a store, or a
client. The recipient map sorts and joins joint-owner keys, rejects
duplicates after canonicalization and any value that is not a non-empty
`recipient_` id, and the configuration tests prove each refusal exits with the
resolution code. The production composition root installs the fail-closed
reader and the sanctioned-model evaluator, which is the state plan 46 says
production is in.

## Follow-ups that do not block

- Two interpreters exist for `PracticeReviewAttention`. Production installs
  `runPracticeReviewAttentionAtomic` whenever the flow patch is active and
  the generic `runPracticeReviewAttention False` otherwise; the generic
  interpreter's `attention` callback is a stub in every production runtime
  ("legacy practice-review attention is unavailable"). The `False` branch
  satisfies rule 2 of the versioning guide formally, but a reader has to
  work out that it can only be reached by a journal that predates the patch,
  which no journal does. A comment at the branch would save the next reader
  the trace.
- `runPracticeReviewEvaluator` throws inside the `step`, so a provider
  failure or invalid JSON is not journaled and the model is called again on
  each crash retry. That is the right behaviour for a transient provider
  error and the wrong one for a model that deterministically returns
  non-JSON; bounding retries on the second case is a policy question for the
  evaluator, not this module, but worth a note where the runtime is
  composed.
- The raw proposal journaled under `practice-review-evaluate` is unbounded.
  `boundedEvaluatorDetail` truncates only error text. A response-size cap
  before journaling would keep a misbehaving model from writing an arbitrarily
  large step row.
- `EvidenceBundle` and `RecalledPracticeReviews` are sent to the model whole.
  Prior memory includes every retired and do-not-repeat resolution the recall
  returned; that is by design, but the prompt has no size ceiling either.

## Evidence

- `Capability.hs` lines 85-105 (context reader), 331-378 (journaled
  interpreters), 177-216 (recipient map canonicalization), 248-258
  (fail-closed production runtime), 276-290 (model evaluator).
- `Agent/Workflow.hs` lines 821-838 install the five interpreters and choose
  the atomic attention interpreter on the patch; `Workers/Config.hs` line 218
  installs `failClosedPracticeReviewRuntime`.
- `Flow.hs` lines 67-82: the effect row.
- `AppConfigSpec.hs` "practice-review recipients reject noncanonical
  destinations and duplicate owner sets" and the surface/default tests
  passed at the reviewed commit; the orchestration group passed 9 of 9.
