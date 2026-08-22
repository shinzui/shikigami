# 0022. The journal ends at enqueue and receipts own delivery truth

Date: 2026-08-21

Status: accepted


## Context

An agent workflow commits its sink intent and Keiro outbox row in the same
transaction, then completes before the worker performs any downstream HTTP. The
journal used to call that transaction `Delivered`, even though delivery could
still retry ten times and end dead. It also discarded the downstream id after a
successful publish, leaving no queryable proof with which to suppress a repeated
Kizashi signal or reuse a Danwa conversation that had already been started.

The workflow journal and the outbox answer different questions. The journal says
which deterministic workflow decisions committed. The outbox says whether its
transport should be retried. Neither can hold the downstream id without either
reopening completed workflow history or changing framework-owned state.

Downstream services do not all accept a client idempotency key. Kawa deduplicates
Shikigami's deterministic source-event id, but Kizashi mints a signal id per
request and Danwa mints conversation and message ids. A client-side guard can
therefore reduce duplicates but cannot remove the crash window between a
downstream acknowledgement and a local receipt commit.


## Decision

**The durable workflow journal stops at `Enqueued`; Shikigami's receipt ledger
owns publication truth after that boundary.**

`shikigami.sink_deliveries` records one main receipt keyed by the outbox message
id. Enqueue writes `pending` in the same transaction as the journal and outbox
row. The publisher writes `attempting`, then one of `delivered`, `failed`,
`dead`, or `unknown`; a delivered receipt retains the downstream id. Only
`delivered` proves that the transport may return success without sending again.
Missing, pending, failed, dead, and unknown receipts never masquerade as proof of
delivery.

Multi-step transports may record sub-receipts under
`<outbox-message-id>#<substep>`. Danwa uses `#conv`: after start and join it
records the conversation id before posting the first message. A retry consults
that receipt and posts into the same conversation rather than starting another.
Sink modules receive this ability as an optional `DeliveryGuard`; they do not
depend on PostgreSQL.

A downstream acknowledgement followed by a receipt-write failure returns
publication success and emits a critical `unknown` record/event. Retrying at
that point would knowingly risk repeating an acknowledged effect. This is not an
exactly-once guarantee: a process can still die between the downstream response
and any local write. Server-side idempotency keys remain the only way to close
that window.

Independent sinks in an agent run use ordering keys `<run-id>:<ordinal>` so one
retrying transport does not head-of-line block another. Conversation-reply and
flow step paths retain their shared per-run key where order is meaningful.

The additive `PermanentFailure` outcome maps through Keiro 0.14's public
`PublishRejected` outcome. Shikigami constructs a bounded rejection with code
`sink.permanent-failure` through `mkPublishRejection`, preserving the transport
error as its detail. The main receipt must first commit as `dead`; only then may
the publisher return `PublishRejected` and let Keiro record its separately
terminal `rejected` outbox state. If the receipt write fails, the callback
returns `PublishFailed` so Keiro does not make a terminal claim that
Shikigami's own delivery ledger cannot substantiate. Shikigami never mutates
Keiro-owned tables.


## Alternatives rejected

**Write the final result back into the workflow journal.** The worker publishes
after the workflow may already be complete. Reopening its history would make an
asynchronous transport fight Keiro's workflow model and add replay/versioning
work to a fact that belongs outside workflow execution.

**Treat a successful outbox insert or any non-error dispatch result as delivered.**
That reproduces the original lie. A durable intent, a permission denial, and a
downstream acknowledgement are different facts and remain different states.

**Return a retryable failure when the downstream acknowledged but the receipt
commit failed.** That is locally tidy and operationally unsafe: Kizashi and
Danwa can create a second effect. The uncertainty is recorded honestly instead.

**Give every sink a database pool.** This couples transport code to storage and
makes direct dispatch need a database. The narrow `DeliveryGuard` carries only
the two sub-receipt operations a multi-step transport needs.


## Consequences

Operators query `shikigami.sink_deliveries` for delivery truth and downstream
ids; the workflow journal intentionally says only `Enqueued`. Historical
`Delivered` journal values remain decodable because the outcome change is
additive.

Production `AgentRunDeps` must carry the Shikigami pool for publisher receipts.
Focused workflow tests may use the explicitly untracked seam, but the worker
composition root always supplies the pool.

Permanent transport rejection is visible on both sides of the boundary:
Shikigami records a `dead` receipt with the transport detail, while Keiro records
a `rejected` outbox row with the stable rejection code. Worker summaries report
`rejected` separately from attempt-exhausted `dead` rows. HTTP status
classification remains owned by Plan 22; this ADR defines what happens once a
handler produces `PermanentFailure`.

Every new multi-step sink must decide whether it needs a sub-receipt and must
record it before the first non-idempotent step that can be repeated. Receipt
write failures fail closed before a send and become operator-visible uncertainty
after an acknowledgement.

The workflow body gained no step, label, reorder, or branch. The enqueue
transaction grew an additional row and `SinkOutcome` gained additive codecs, so
existing journals replay without a patch; `just keiro-gate` remains the
enforcement point.


## References

* `docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md` — implementation
  plan and acceptance evidence.
* [ADR-0012](0012-a-declared-workflow-body-only-grows-behind-a-patch.md) — the
  workflow-shape rule this change does not trigger.
* `docs/workflow-versioning.md` — Shikigami's durable workflow compatibility
  procedure.
* `mori://shinzui/keiro/plans/165-add-terminal-outbox-publication-rejection-outcomes`
  — the released upstream terminal-rejection contract consumed here.
