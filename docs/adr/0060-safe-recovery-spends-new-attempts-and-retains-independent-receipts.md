# 0060. Safe recovery spends new attempts and retains independent receipts

Date: 2026-10-28

Status: accepted

## Context

A dispatched attempt whose owner disappears remains unknown. Some trusted
operation classes permit another actual attempt, but that attempt cannot erase
the earlier transport's accounting or discard a later real receipt. In
particular, a late former reply must not replace the chosen replacement result.

## Decision

Recovery may repeat a trusted observation or an idempotent effect under the same
accepted logical operation, input, binding and trusted idempotency key. It
allocates a new actual attempt and reservation. A new bounded policy field,
`recoveryAttempts`, defaults to two for fresh policy values, supports 0–100, and
can only be narrowed by agent overrides. Historical absent fields decode to
zero and remain omitted on encoding. Uncertain effects never redispatch merely
because a claim expires.

One checked transaction retires the unknown attempt as superseded, reserves and
enqueues its replacement, and reopens logical progress. It retains the earlier
unknown reservation and increments a pending-receipt count. Capacity, profile,
permission, policy and fresh authority checks still apply. A refusal rolls back
the entire change and leaves the original unresolved state. Tool recovery
restores the exact response/position cursor from its immutable input; it cannot
skip the tool by interpreting uncertainty as a new model turn.

Superseded queue deliveries are observations and never signal a replacement's
awakeable with an old reference. A real former-owner receipt proves only that
actual attempt's accounting. Its acceptance and settlement share a transaction,
retain protected receipt data and decrement the pending count, without changing
the chosen operation outcome, logical cursor, next work or terminal result.
Identical repeats converge; conflicting receipts refuse. These factual writes
do not grant replay reads or new external authority.

The execution lifecycle keeps its historical terminal states and transitions.
New internal pending-receipt states allow a logically succeeded, failed or
cancelled execution to settle older actual attempts after its child finishes.
Final receipt closure has a distinct event so replay attributes each transition
unambiguously. Closing the last receipt reaches the original terminal state.
The public execution phase stays terminal throughout. Partial billing can remain
unknown in the resource owner even after transport completion is established.

## Alternatives rejected

Releasing the unknown attempt to make room for its replacement would invent
unused capacity. Reusing its actual attempt identity would hide transport cost.
Reopening the old terminal states would weaken their historical contract.
Overwriting the operation with a late response would replace accepted progress.
An independent retry queue would duplicate the existing fenced executor owner.

## Consequences

Finite active capacity can intentionally prevent recovery while an unknown call
still holds its slot. The operation remains visible and awaits evidence.
Accepted model turns and physical transport attempts have separate counts.
Generated fold fingerprints invalidate aggregate snapshots after this additive
extension; historical event replay and all behavior cells must pass the gate.
Real mutable workspace fencing remains owned by IR-11. This contract supplies
the harness seam and does not claim that a generic native tool is idempotent.

## References

- [Plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md)
- [ADR 0051](0051-resource-roots-own-conservative-reservations-and-actual-attempts.md)
- [ADR 0054](0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md)
- [ADR 0059](0059-harness-policy-is-frozen-at-admission-and-shared-with-ephemeral-execution.md)
