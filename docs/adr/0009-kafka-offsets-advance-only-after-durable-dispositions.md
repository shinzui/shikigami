# 0009. Kafka offsets advance only after durable consumer dispositions

Date: 2026-08-19

Status: accepted


## Context

Shikigami turns Kafka records into agent-run jobs. Three facts determine whether
one delivery is safe to forget: the Keiro inbox row says the integration event
was accepted, the PGMQ run queue contains every matching `RunJob`, and the Kafka
consumer group's offset has advanced beyond the record.

Those facts used to be established in the wrong order. The inbox transaction
committed first, an IO callback enqueued the job afterwards, and the hand-written
poll loop committed the Kafka offset regardless of either outcome. A crash in the
inbox-to-enqueue gap left a completed inbox row with no run job; redelivery then
looked like a duplicate and could never repair it. A transient Postgres failure or
an undecodable record was logged and committed over, losing the delivery.

PGMQ and the Keiro inbox are tables in the same Postgres database. Keiro runs its
inbox handler inside a caller-extensible Hasql transaction, and PGMQ exposes a
transaction-composable send statement. Kafka cannot participate in that database
transaction, so its offset must remain the last fact established and may advance
only after Postgres proves a durable terminal outcome.

The Kafka client adds one more constraint. librdkafka stores the highest offset per
partition without gap tracking. The released Shibuya Kafka adapter therefore
requires serial handling; concurrent acknowledgement could store a later offset
past an earlier failed delivery.


## Decision

**A Kafka delivery authorizes offset advancement only after Shikigami has
established an explicit durable terminal disposition. Shibuya is the sole owner
of the corresponding broker acknowledgement.**

Concretely:

* A matching event's Keiro inbox row and every PGMQ `RunJob` commit in one
  Postgres transaction. Queue creation is reconciled at process startup and never
  runs inside that transaction.
* Consumers return one of `Enqueued`, `Duplicate`,
  `PermanentlyDeadLettered DeadLetterId`, or `TransientFailure Text`. The first
  two become `AckOk`; a durable permanent failure becomes `AckDeadLetter`; a
  transient failure becomes `AckHalt`.
* Undecodable transport envelopes and payloads are written to the configured
  `kafka.dead_letter.queue` PGMQ queue before they become permanent. Each record
  retains topic, partition, offset, a bounded error, total payload size, and at
  most 256 payload bytes. If that send fails, the disposition is transient and
  the offset cannot advance.
* Both subscriptions use the released Shibuya Kafka adapter with
  `StrictInOrder` and `Serial`. Application code neither polls Kafka directly nor
  imports an offset-commit operation.
* `AckHalt` tears down the consumer session. The outer supervisor reconnects with
  a 1, 2, 4, …, 30-second capped delay and resumes from the last stored offset.
* Typed Kiroku store-startup and returned store failures are transient. Any other
  synchronous handler exception is recorded long enough to return `AckHalt
  HaltFatal`, then rethrown outside Shibuya so the process supervisor sees a
  programming failure without committing its record.


## Alternatives rejected

**Keep the enqueue in the post-inbox callback.** Idempotent job keys do not repair
a missing job after the inbox has already classified its redelivery as duplicate.
A reconciliation sweeper would add a second state machine for a boundary Postgres
can already make atomic.

**Commit after every handler return and rely on logs for poison records.** Logs are
not recoverable state. This makes both a database outage and malformed producer
output indistinguishable from successful consumption at the broker.

**Return a terminal Kafka acknowledgement for poison before storing it.** The
Shibuya Kafka adapter deliberately has no DLQ producer. Its `AckDeadLetter` alone
stores the offset and makes the original record unavailable from that consumer
group, so application-owned persistence must happen first.

**Retain the hand-written poll/commit loop.** That leaves two possible owners of
offset state and bypasses the adapter's serialized poll, seek, pause, store, and
shutdown mechanics. The implementation would have to reproduce those invariants
while remaining less reviewable.

**Use concurrent partition processing.** The adapter cannot track offset gaps.
Even concurrency across apparently independent work risks storing a high-water
offset past a failed record in the same partition; `StrictInOrder` plus `Serial`
is the supported safe policy.


## Consequences

The consumer is deliberately at-least-once between Postgres commit and Kafka
offset storage. A crash in that gap redelivers the record, but Keiro returns
`Duplicate` only after the original transaction has already committed its run
jobs, so the replay safely authorizes `AckOk`.

The database transaction gives a stronger local invariant: a delivery cannot
leave a completed inbox row without its run jobs, and a failed queue send leaves
neither. The worker's existing workflow idempotency key remains a downstream
defence rather than compensation for a broken producer boundary.

Operators gain a new durable queue and setting. The default queue is
`shikigami_stream_dead_letters`; both consumer roles create it idempotently before
joining Kafka. Deleting or making it unavailable intentionally wedges a poison
record until persistence recovers, because progress without evidence would be
data loss.

The released adapter's public envelope preserves Kafka headers, value bytes,
partition, and offset, but not the record key. Current Shikigami activity/event
matching, inbox dedupe, and job identity do not consult `IntegrationEvent.key`, so
this does not change trigger results. A future feature that needs the key must
first extend `mori://shinzui/shibuya-kafka-adapter`; it must not restore a private
poll loop.

`AckDeadLetter` still emits the adapter's warning that it has no Kafka DLQ
producer. In Shikigami that warning means the Kafka copy is being retired; the
preceding structured log carries the PGMQ `DeadLetterId` that makes the record
recoverable.


## References

* `docs/plans/18-atomic-stream-consumption-offsets-inbox-and-enqueue-in-one-boundary.md`
  — implementation evidence, acceptance tests, and the dependency audit.
* `shikigami-workers/src/Shikigami/Trigger/Consumer.hs` — disposition-to-ack
  mapping, PGMQ poison persistence, and serial supervision.
* `shikigami-core/src/Shikigami/Trigger/Enqueue.hs` — the transaction-composable
  run-job send.
* `mori://shinzui/keiro/packages/keiro` — inbox transaction and durable failure
  semantics.
* `mori://shinzui/pgmq-hs/packages/pgmq-hasql` — transaction-composable PGMQ
  statements and queue management.
* `mori://shinzui/shibuya-kafka-adapter/packages/shibuya-kafka-adapter` — offset
  storage, retry/seek, halt/pause, serial-operation, and no-DLQ contracts.
