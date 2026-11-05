# 113. Unrequested proposals park on the approval child, keyed by observer and subject

Date: 2026-11-04

Status: Accepted

## Context

Several people can restate one problem, a broker can redeliver a message, and a worker
can crash between a decision and its record. An agent proposing work nobody asked for
must converge on one proposal through all of that, must not spend attention on a
subject already owned, and must wait for a person by default.

## Decision

A proposal is keyed by observer principal and source subject through a versioned
digest. A partial unique index admits one pending row per key, and the pending row is
the owner: a losing allocated id is discarded, as
[ADR 0073](0073-objective-identity-is-allocated-and-creation-receipts-own-deduplication.md)
does for objectives. The activity id is not part of the key because every restatement
has a new one.

Before evaluating, a run checks the ledger for an owner: a pending proposal, an
accepted or admitted proposal whose objective is still open, or a rejection or expiry
inside its suppression period. An objective whose state cannot be read counts as open,
because a missed proposal is recoverable and a competing one is not.

The `propose-work` Flow lives inside the agent run behind `shikigami-initiative-v1`
and reaches the ledger through an `Initiative` capability whose operations are each
one journaled step. A proposal parks on the existing durable approval child
([ADR 0030](0030-an-approval-request-is-a-durable-child-workflow.md)) through a
deadline-carrying acknowledgement operation, so the wait is the proposal's own expiry
rather than the run's approval deadline. Acceptance creates one objective under the
agent's existing default-deny creation grant
([ADR 0068](0068-objective-creation-has-authority-before-association.md)) with a
nominal link to the proposal and its observed source. Silence expires the proposal
and, like rejection, suppresses the subject for the allowance's declared period.

The pre-filter runs at the stream trigger and again in the Flow as the same pure
function. An irrelevant message costs one bounded row inside the inbox transaction
([ADR 0009](0009-kafka-offsets-advance-only-after-durable-dispositions.md)) and no
workflow, while a run re-derives its sealed candidate from the journaled envelope and
never trusts intake.

Evaluation attention is spent when a run opens under the observer's anchor lock, not
when intake enqueues it. Counting at intake would let queued work consume the window
and let a crashed retry count itself.

## Alternatives

A new wait primitive and a new workflow family were rejected because the agent run
already supplies the recorded principal, the journaled policy, the objective scope and
the sink path, and the approval child already supplies a stable review id, an opaque
token and `shikigami resolve-approval`. Keying by activity id was rejected because it
would make one proposal per restatement. Model output was rejected as a key because it
is not stable. A provider call in the stream consumer was rejected because it would be
neither journaled nor replay-safe.

## Consequences

There is at most one pending proposal per observer and subject. A worker restart loses
neither the park nor its deadline. A proposer declares no run-end sinks, because the
run-end path would notify on skips; every message a person sees leaves through the ask.
A rejected subject stays quiet for the suppression period even if it is restated, which
is the point and is also a way to miss a genuinely new problem on the same subject.
