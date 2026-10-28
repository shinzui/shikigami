# 0053. Execution lifecycle and protected replay share an atomic boundary

Date: 2026-10-27

Status: accepted

## Context

A recoverable Skill needs its accepted instructions, model context, tools,
continuation facts and outcomes after a process exits. Semantic memory and call
evidence have separate purposes and cannot reconstruct that sequence. Baikai's
Response, Context, Options and ModelCallEvidence have no supported replay decoders.
An outcome committed separately from its resource settlement or progress cursor
would admit contradictory histories after a crash.

## Decision

The generated `ExecutionLifecycle` aggregate owns lifecycle transitions. Small,
versioned events identify the execution, immutable snapshot digest and monotonic
revision. Rich snapshots and outcomes live in application-owned SQL rows written
by a captured live projection in the same command transaction. The shared
generated projection catalog owns these targets and the registered immediate
query model. Both live-projection factories preserve the other owner's sets.

`Execution.Transcript` owns explicit versioned replay records. Assistant text,
thinking signatures, redacted reasoning and ordered provider continuation items,
tool name/arguments/id, stop reason and supported message blocks remain intact.
Original usage and raw provider evidence are protected JSON; normalized accounting
uses the existing call facts and resource owners. Restored provider history uses
zero SDK usage because history rendering does not consume those measurements.
The original measurements remain durable and never become zero in accounting.

An execution derives from its stable assignment identity. Logical operation ids
derive from that execution and a committed cursor, rather than retry-local counts
or provider ids. Each immutable request fingerprint binds its input reference,
operation specification and original snapshot digest. Changed retries refuse.
An accepted outcome also binds its continuation, so a duplicate cannot replace
the next progress decision.

Protected payloads have a one-mebibyte limit, digest and execution-scoped reference.
Their table revokes PUBLIC privileges. Runtime replay requires a private,
short-lived, principal/execution-bound read permit; metadata inspection returns
references and at most 100 operations. Protected structures have redacted `Show`
instances. The private query model captures the store's parameterized transaction,
with its permit check, under the registered schema and catalog read fence. Its
input is process-local code and has no wire decoder. Offline projections refuse
both replay and ordinary inspection.

Lifecycle event append, protected outcome, next cursor, normalized call facts and
root settlement commit together. Projection refusals roll back every participant.
Stream rejection and a captured transaction refusal remain distinguishable, so
idempotency lookup never hides an owner refusal. Storage failures return bounded
error identities rather than SQL parameters or replay bodies. Accepted operation
facts can be recorded after authority or read-permit expiry; that permission
grants no replay read or fresh dispatch. Root cancellation still prevents new work.

Terminal success reads the accepted assistant, applies its pinned output policy
and verifies the supplied result equals that derivation. A reply cannot be
invented at the terminal write boundary. Unknown effects retain their reservation
and cursor and require explicit reconciliation. Payloads and deduplication facts
have no automatic deletion path; workflow GC cannot release their retention.

## Alternatives rejected

Upstream-shaped decoders would invent an unsupported compatibility contract.
One coarse workflow result loses intermediate operations. Separate outcome and
accounting transactions leave a crash gap. Raw prompts in operator rows defeat
protected replay. An unfenced read could consume a partial repair. A new catalog
or replacing unrelated projection sets would split ownership.

## Consequences

The execution runner must consume this storage boundary and account each actual
attempt separately. Policies, permission binding, executor claims and queue-driven
recovery are the remaining consumers in plan 83. This storage acceptance does
not establish production model/tool recovery by itself. The resource owner's
`execution_operations` table remains separate from the transcript owner's
`execution_transcript_operations`; they correlate by logical operation identity.

## References

- [Plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md)
- [ADR 0010](0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md)
- [ADR 0051](0051-resource-roots-own-conservative-reservations-and-actual-attempts.md)
- [ADR 0052](0052-assignments-pin-whole-run-selection-and-account-every-provider-attempt.md)
- `mori://shinzui/keiro/packages/keiro` — selected 0.18.0.0 public command, catalog and query boundaries.
- `mori://shinzui/baikai` — supported content/continuation constructors and encode-only provider envelopes; artifact-level source URIs are pending.
