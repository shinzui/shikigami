# 0054. Execution attempts own dispatch fences and generation wakes

Date: 2026-10-28

Status: accepted

## Context

A durable operation can outlive the worker and queue delivery that started it.
Redelivery cannot distinguish an undispatched reservation from an external effect
whose response was lost. A late worker must not advance the cursor or release
another attempt's reservation. Accepted outcomes can also survive a failed wake
publication. Queue visibility and workflow concurrency do not prove dispatch or
completion.

## Decision

Dispatch state occupies a new `dispatches` column on the existing owned operation
table, separately from the resource owner's `execution_attempts`. Each logical
operation admits at most 1,000 actual attempt records. Indexed queries project
one attempt without decoding or exposing the full map. A nominal transaction
lock serializes attempt-id collision checks across roots under the store's
ReadCommitted contract. This preserves the established projection group, query
identity and ownership footprint; old writers preserve the additive column.
The checked execution command transaction
reserves the actual attempt, retains its immutable request and protected wake,
and accepts its queue entry together. The existing run-job queue carries explicit
execution/operation/attempt references. Version 4 admits this route; historical
v1–v3 inputs cannot acquire it through an upcaster. Queue delivery never allocates
an actual attempt.

Each attempt has an owner, monotonic claim generation and absolute lease expiry.
A conditional dispatch-start transition is the authority for one executor to run
IO. Repeated starts permit observation only. Expiry before dispatch permits a
replacement claim on the same reservation. Expiry after dispatch exposes an
unresolved operation with its cursor and unknown reservation retained. It never
proves that an external effect stopped. A known refusal before dispatch releases
active capacity but retains the spent attempt; a safe retry reserves another
actual attempt under the same logical operation key.

Accepted outcome, cursor, claim completion, call facts and resource settlement
share the command transaction. A stale claim cannot commit them. Its actual late
receipt remains protected reconciliation evidence. Reconciliation consumes that
retained receipt, rather than sampling another result. It preserves previous
known measurements, observations and immutable identities. A terminal HTTP error
proves transport stopped even when billing is unknown; a transport exception
remains unknown. Recovery from unknown transport to partial billing releases
active work once, retains unknown billing once and never charges counters twice.

The prepared provider path validates the exact request fingerprint and pinned
binding and never reserves again. Its private handle admits one blocking or
streamed invocation. Both paths use the same atomic terminal hook. Raw responses
use the application replay codec; no upstream decoder is invented. A known
outcome can repair wake publication after restart or authority revocation without
provider lookup or redispatch.

An unfinished tool reacquires only the exact needed capability revision. Trusted
native factories receive the logical idempotency key outside model arguments.
Bindings include schema, revision, recovery class and explicit invoice semantics.
The tool interpreter refuses nested model calls through a process-global registry;
those require their own accepted operations. Model token usage is therefore an
enforced zero for these tool transports. Generic tools default to unreported
invoice cost, keep it unknown and refuse finite invoice ceilings. Only a trusted
non-invoiced native factory can declare zero invoice cost. Rich observations keep
native blocks, structured data and opaque extensions. Cleanup failure cannot
erase an already committed observation.

Wake tokens remain in protected payloads. Rotation publishes the current
generation's token separately from the immutable attempt request. Completion
signals that publication. The one timer dispatcher owns observation deadlines;
a timer may complete only its recorded generation. Its public Keiro transaction
appends to that explicit generation, including during a concurrent rotation.
Obsolete timers are cancelled instead of appending a wake to their successor.
Technical workflow ids are stable UUIDv5 identities derived from execution ids;
resource digest prefixes never enter Keiro's separator-sensitive workflow ids.

Whole-assignment selections refuse nonempty private header/metadata settings.
API credentials remain in their opaque live binding. This prevents private
metadata or header credentials from becoming replay state or journal options.
Explicit unsupported configuration refuses rather than redacting or changing the
request's semantics.

## Alternatives rejected

Queue redelivery allocating an attempt would spend allowance twice and could
repeat an uncertain mutation. Lease expiry cannot establish absence of an effect.
Settling before transcript acceptance leaves contradictory crash histories.
Changing the established catalog target set would require breaking its persisted
rebuild/query identities. The bounded operation map preserves those identities.
Dropping stale receipts discards potentially useful work. Semantic memory cannot
replace exact accepted results. An old generation's token cannot be republished
as a current wake. Unknown invoice cost cannot become an inferred zero.

## Consequences

These primitives are consumed by the worker's explicit execution route and shared
runtime. The automatic execution driver, agent/conversation patch branches,
operator/agent policy wiring and full recovery qualification remain in plan 83.
This acceptance does not establish production Skill recovery by itself. Retention
must preserve attempt requests, unknown outcomes, late receipts and wake facts
independently of workflow GC. Generic workspace and objective ownership remain
separate provider gates.

## References

- [Plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md)
- [ADR 0022](0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md)
- [ADR 0051](0051-resource-roots-own-conservative-reservations-and-actual-attempts.md)
- [ADR 0052](0052-assignments-pin-whole-run-selection-and-account-every-provider-attempt.md)
- [ADR 0053](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md)
- `mori://shinzui/keiro/packages/keiro` — selected 0.18.0.0 public catalog, awakeable, generation-specific journal and timer transactions.
- `mori://shinzui/keiro/packages/keiro-pgmq` — selected 0.18.0.0 delivery/retry contract.
- `mori://shinzui/baikai` and `mori://shinzui/shikumi` — selected supported provider, terminal-event and rich-tool APIs; artifact-level source URIs are pending.
