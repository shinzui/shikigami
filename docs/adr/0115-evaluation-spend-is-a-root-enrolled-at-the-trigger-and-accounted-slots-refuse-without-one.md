# 115. Evaluation spend is a root enrolled at the trigger, and accounted slots refuse without one

Date: 2026-11-04

Status: Accepted

## Context

An agent that observes a stream could spend on every matching message, and a synchronous
Flow decision reserves nothing against a resource root: it only records evidence. Accounting
every Flow decision would change existing Flows that run under roots, and a run started by a
stream consumer has no root unless something enrolls one.

## Decision

Observation is default-deny. An observer allowance in process configuration names a verified
principal, the sources it may read, a resource envelope for each evaluation and limits per
window. The stream consumer enrolls a per-run root from that envelope in the same inbox
transaction that commits the job and the candidate row, because `enrollRootRun` refuses
descendants and the inbox transaction is the only place they become one fact. The root's
cutoff is relative to receipt, not occurrence, so a replayed old activity still gets a usable
envelope.

Decision slots declare their accounting through a total function on `DecisionLabel`.
`RootAccountedCall` admits and settles each actual provider call on the run's root, a root
that refuses stops the call before dispatch, and a run without a root refuses before the
prepare step is journaled. Every existing label stays `UnaccountedCall`. A new slot states its
answer in that function.

An evaluation envelope must name `ActiveWork`, `ModelAttempts`, `Tokens` and an unbounded
`CostMicroUsd`, because a root admits a model attempt only with all four and no ceiling can be
reserved for cost before a call. Decoding refuses anything else, so a misconfiguration is a
startup error rather than a refusal every message would silently take.

Attention limits are bounded indexed counts over ledger rows, serialized by an observer anchor
row. They are not a second accounting owner. An evaluation counts when its run opens, not when
intake enqueues it.

## Alternatives

Accounting every synchronous decision was rejected because it would change existing Flows and
refuse fixtures that never declared model attempts. Declaring spend in the agent declaration
was rejected because attention and spend belong to the operator, and installing an agent must
not grant them. Reservations for attention were rejected because counts need none.

## Consequences

A root that refuses fails the evaluation run rather than recording a skip, because `decide`
aborts on refusal; the candidate stays `evaluating` and the run shows the failure. Crossing a
crash between admission and settlement leaves a held attempt the root reports as unknown, which
is the honest outcome under
[ADR 0051](0051-resource-roots-own-conservative-reservations-and-actual-attempts.md). Another
slot that needs root accounting adds one case to the function rather than a second mechanism.
