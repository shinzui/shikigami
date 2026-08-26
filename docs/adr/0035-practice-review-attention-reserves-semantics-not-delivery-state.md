# 0035. Practice-review attention reserves semantics, not delivery state

Date: 2026-08-26

Status: accepted


## Context

Workflow replay prevents one review run from enqueueing attention twice, but equivalent disputes
can arise in distinct workflows with distinct review, workflow, session, and revision names.
Kizashi does not accept a caller-supplied idempotency key, so reserve-then-enqueue leaves a crash
window: a committed reservation can suppress the only downstream signal even though no outbox
message exists.

Shikigami already assigns delivery truth to `shikigami.sink_deliveries`. Adding pending/delivered
status or a downstream signal id to a review reservation would create a second state machine whose
answers could disagree with the outbox receipt.


## Decision

Actionable practice reviews derive a frozen UUIDv5 `AttentionKey` from normalized semantic inputs:
target and practice scope, classification, owner role, explicit resolved recipient, recommended
action, material claims, and cited evidence content identities. Run identity, `ReviewId`, workflow
identity, session identity, and revision names are excluded. Every distinct review is linked to the
key in an association table.

The semantic key determines the outbox message id before reservation. One database transaction
appends the workflow journal result, inserts or observes the reservation, links the review, and,
for the winner only, inserts the prepared Kizashi outbox message and pending delivery receipt. The
winner records `Reserved`; contenders record `Coalesced` with the winner's message id. A lifecycle
or grant skip journals its ordinary sink result without creating a reservation.

The reservation stores logical identity and the winning outbox id only. Delivery status, retries,
last error, timestamps, and downstream signal id remain exclusively in
`shikigami.sink_deliveries`. A failed, dead, or unknown delivery never releases the semantic key;
operators repair the existing outbox/receipt identity.


## Alternatives rejected

**Use `ReviewId` as the attention key.** Rejected because trigger-specific ids cannot coalesce an
equivalent dispute across runs.

**Reserve and enqueue in separate transactions.** Rejected because a crash between them can lose
the only signal permanently.

**Copy delivery status into the reservation.** Rejected because two authorities would diverge
during retry and crash-window reconciliation.

**Release a key after terminal delivery failure.** Rejected because resubmission would create a
second semantic signal instead of repairing the known delivery identity.


## Consequences

Equivalent reviews retain separate Kawa history and audit associations while sharing one Kizashi
attempt. A changed recipient, classification, claim, action, or cited content identity produces a
new semantic key. Recipient mapping is explicit and fail-closed; the global Kizashi fallback does
not participate.

Operational queries join `practice_review_attention.outbox_message_id` to
`sink_deliveries.outbox_message_id`. Schema changes to the semantic projection or frozen namespace
require a new version. The transaction necessarily uses the store boundary beneath the Flow
capability, while the Flow body itself retains no raw store or IO access.


## References

* [`docs/plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md`](../plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md)
  — implementation and concurrent conformance evidence.
* [ADR 0013](0013-flow-bodies-reach-the-world-only-through-capabilities.md) — replay-safe Flow
  capability boundary.
* [ADR 0022](0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) — sole delivery
  authority.
* `mori://shinzui/kizashi/repos/kizashi` — downstream signal API and generated signal identity.
* `mori://shinzui/kawa/packages/kawa-api` — distinct historical activity idempotency and context
  references.
