---
type: Improvement Request
title: Register a product-review Flow over payload-supplied evidence
description: Generalize the advisory practice-review ports into a registered Flow that validates commit-pinned evidence from the run payload, drafts a closed report, judges each item with a typed TypeSafe program, and records memory, history, and coalesced attention under exact authorization.
timestamp: "2026-11-12T18:00:00Z"
generated:
  by: process:claude-code
  at: "2026-11-12T18:00:00Z"
requestId: IR-26
status: proposed
origin: mori://tan/tan-product-management
---

# Register a product-review Flow over payload-supplied evidence

## Status

**Proposed; no implementation plan selected.** This request comes from
`mori://tan/tan-product-management/masterplans/2-add-shikigami-product-management-reviews-and-follow-up`,
which reviewed Shikigami at commit `ba602ead`. It is the runtime half of
`mori://tan/tan-product-management/plans/11-run-recurring-product-reviews-with-durable-history-and-delivery`,
whose first milestone cannot start without it. The draft stage runs live only after
[IR-25](run-subscription-backed-generative-steps-in-durable-flows.md). Everything
else can be built and qualified first with stub or loopback providers.

## Problem and current coverage

The consumer runs a weekly advisory review of a product-knowledge repository. Its
output is a brief of at most five product decisions needing attention, each with
cited evidence, missing evidence, and a proposed next action. A host feeder builds a
bounded snapshot from one immutable commit and submits it as the payload of an
addressed run over `POST /agents/{agentName}/runs`, keeping it within the
65,536-byte bound. The consumer's one-off pilot,
`mori://tan/tan-product-management/plans/10-prove-a-bounded-shikigami-product-review-from-repository-evidence`,
defines the v1 input and output contracts and must be accepted before this Flow is
used.

[CAP-15](../capabilities/advisory-practice-review.md) already has most of the shape:

- `PracticeReviewEvidence` resolves pinned content references. Its production reader
  is fail-closed with `content-plane-unavailable`.
- `PracticeReviewEvaluator` takes an `EvidenceBundle` and `RecalledPracticeReviews`
  and returns one JSON value, requested as `JsonObject`.
- `Memory.hs` records provisional and resolved review memory, and `Attention.hs`
  derives semantic attention keys.
- `shikigami-core/src/Shikigami/Flow/OpenTelemetryPracticeReview.hs` composes these
  for the one registered specialist.

[CAP-21](../capabilities/typed-flow-decisions.md) and the registered
`shikumi-judgment-example` show a TypeSafe judgment with pinned thresholds and raw
answers retained beside derived results.

No registered Flow accepts evidence from its payload, drafts a report, judges its
items, and publishes the result. A manifest that names an unregistered Flow does not
create one, so the consumer cannot assemble this from declarations.

## Requested change

1. Register a `product-review` Flow in `Shikigami.Flow.flowRegistry`, generalized
   from the practice-review ports rather than written as a separate publication
   module. Use static journal labels behind a permanent patch id, as the
   practice-review memory does, and follow `docs/workflow-versioning.md`.
2. Supply an evidence implementation that reads the closed v1 input from the trigger
   payload. It checks the contract version, the full 40-character source commit, each
   document's relative path and canonical reference, and each content hash against
   the supplied text. Payloads with unknown versions, mismatched hashes, or paths
   outside the vocabulary of ADR 0008 are refused. Operator configuration names the
   accepted producer (HTTP caller), project URI, contract hash, and instruction-text
   hash; a payload cannot authorize itself.
3. Draft stage: evaluate the bundle, the agent's own recalled prior briefs, and the
   hash-checked instruction text through a generative binding under the agent's
   pinned sanctioned profile, requesting JSON-schema output for the v1 report. Use
   the IR-25 CLI binding when it exists; HTTP and stub bindings work until then.
4. Validate the draft before any memory or sink work. Check that the output contract
   is closed, the source identity and mode match the input, there are at most five
   items, every citation names a supplied document and hash, and each item key
   recomputes from the mode, its sorted subject references, and a closed issue
   category. Refuse owner, deadline, or lifecycle-state assertions that the cited
   evidence does not contain, where that is mechanically checkable. An invalid draft
   ends as a structured unresolved result, as missing evidence does in the practice
   review.
5. Judgment stage: run a registered TypeSafe judgment program on each validated
   item. It produces, for example, a thresholded "needs attention now" predicate and
   a severity. Pin the thresholds in the program, retain the raw answer beside the
   derived result, and record both in the report's optional details area without
   changing any v1 field. Order the brief by the judgments. A judgment failure
   leaves the draft as unjudged history with no attention reservation.
6. Memory: record one provisional review memory per accepted brief, with a
   deterministic id derived from the run's review key, and recall a bounded set of
   the agent's own prior briefs into the next draft. The declaration uses automatic
   memory policy `Never`, so a failed or unvalidated result is never stored as
   accepted history.
7. Emissions: one `KawaDigest` history activity per validated brief, and a
   `KizashiSignal` digest item to the configured recipient only for items judged as
   needing attention. Attention keys equal the item keys, so equivalent items
   coalesce across runs. Both go through exact-action authorization and the outbox,
   with delivery truth owned by receipts per ADR 0022.
8. The Flow acquires no workspace tools, runs no scripts, and reads no repository.
   [IR-24](read-pinned-allowlisted-repository-evidence-in-durable-runs.md) could later
   supply evidence through the same port without changing the report contract.
9. Keep a pinned pair of input and output contract fixtures that both this
   repository's tests and the consumer's tests pass. Name the qualified pair in a
   compatibility receipt.

The decision program's labels and thresholds encode the consumer's review policy. Who
authors them, and whether they arrive as reviewed code or operator configuration, is
Shikigami's to choose. Selection, classification, and recommendation rules stay with
the consumer.

## Acceptance

1. A valid fixture payload accepted over HTTP ends `succeeded`. It records one
   provisional review memory and one Kawa outbox intent, plus Kizashi intents only for
   items judged as needing attention. Stub or loopback providers are enough here.
2. A wrong content hash, an unsupported contract version, and an unconfigured
   producer are each refused before any model call, with no memory or sink work.
3. A draft that cites an unknown document, a draft with six items, and a draft whose
   source identity does not match each end unresolved, with no memory or sink work.
4. Replaying the same idempotency key creates no second run. A worker restart between
   sink intent and delivery yields exactly one receipt per sink.
5. A judgment failure records unjudged history and reserves no attention.
6. After the worker's model credentials are removed and it restarts, recorded draft
   and judgment results replay with no new calls.
7. With `authorization.actions.mode=disabled`, every sink is refused visibly and none
   becomes delivered.
8. A declaration without a resolvable sanctioned profile is refused before any model
   call.
9. The same equivalent item in the next week's run maps to the same attention key.
   Trusting runtime coalescing for suppression waits on
   [plan 60](../plans/60-harden-practice-review-attention-reservation-and-specialist-failure-boundaries.md).
10. The shared contract fixtures pass in both repositories.

## Dependencies and scope

This builds on [CAP-15](../capabilities/advisory-practice-review.md),
[CAP-21](../capabilities/typed-flow-decisions.md),
[CAP-13](../capabilities/sanctioned-execution-profiles.md),
[CAP-9](../capabilities/authorized-sink-outbox.md),
[CAP-7](../capabilities/exact-action-authorization.md), and
[CAP-24](../capabilities/idempotent-http-agent-runs.md), and on ADRs 0022, 0031, 0035,
and 0036. The draft stage needs [IR-25](run-subscription-backed-generative-steps-in-durable-flows.md)
for subscription-backed generation, and judgments rely on plan 80's TypeSafe
qualification. This request does not ask for the content plane, repository reads,
resolution ingress, or any authority to edit, merge, or gate a repository. The brief
stays advisory.
