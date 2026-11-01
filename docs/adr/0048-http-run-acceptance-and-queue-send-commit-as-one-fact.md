# 0048. HTTP run acceptance and queue send commit as one fact

Date: 2026-10-25

Status: accepted

## Context

An HTTP request may be retried before a worker creates its workflow. Workflow
idempotency alone cannot prevent duplicate queue messages or make a queued run
readable before drain.

## Decision

Shikigami owns an acceptance ledger keyed by agent and caller-supplied idempotency
key. Acceptance sends the ordinary run job and inserts the ledger row in one
read-committed transaction. A conflicting insert condemns the transaction,
rolling back its send; a fresh read compares the stored payload fingerprint.
New work returns 202, identical replay 200, and a different payload 409.
Accepted facts retain their original caller and timestamp on replay.

The original delimiter-based RunKey is superseded by
[ADR-88](0088-run-keys-separate-caller-and-trigger-coordinates.md). Current HTTP
producers use `httpRunKey`'s structured v2 commitment to agent and caller key.
The public runId is exactly the existing runJobWorkflowId result. Keiro rejects
colon-delimited keys as direct workflow IDs, so the existing UUIDv5 fallback
supplies the ID. Callers retain that ID rather than reconstructing it. CLI and
HTTP share the addressed job constructor and explicitly select AgentWorkflowRoute.

The ledger stores a deterministic UUIDv5 fingerprint of the encoded payload,
not a second payload copy. The API accepts object payloads of at most 65536
encoded bytes and bounded nonempty caller keys. The credential's caller label
is attribution, while deduplication is scoped by agent and key, across callers.


The acceptance record retains native Keiro `WorkflowId` and native PGMQ
`MessageId` rather than Text/Int64 copies. SQL, route, logging, pagination and
public JSON adapters unwrap only at their actual transport seams; workflow
lookup accepts the native coordinate. No identity formula or valid wire value
changes, and neither runtime identity is reallocated or wrapped in a TypeID.

The original URL-namespace UUIDv5 payload commitment is a private
`PayloadFingerprint`. Its parser checks canonical lowercase UUID spelling,
version 5 and the RFC 4122 variant, matching the existing producer. It has no
Generic or unchecked numeric/string construction path. This is a deterministic
technical commitment, not an entity allocation. The original compiled producer's
null/empty-object bytes are retained as literals in value tests. Malformed
fingerprints refuse through the owning decoder and condemn composed reads;
ignored refusals, paging probes and tentative duplicate sends cannot publish
partial work. Exact repair recovers the original message and winner.

Caller attribution is a separate nominal value that captures the authenticated
adapter's exact label without inventing a local grammar. Its factory is total;
the value itself grants no authentication or admission authority. Replay keeps
the original attribution even when the new request is authenticated as another
caller. Native library contracts are owned by
`mori://shinzui/keiro`, `mori://shinzui/pgmq-hs/packages/pgmq-core`, and
`mori://haskell-hvr/uuid/packages/uuid`.

## Alternatives rejected

Queue inspection is not an acceptance model. A separate ledger transaction
could acknowledge a run with no message or send a message with no resource.
Using workflow identity alone would leave duplicate messages and the pre-drain
read gap. Changing CLI production to write HTTP receipts would conflate owners.

## Consequences

Acceptance survives worker downtime and process crashes. Queue reconciliation
happens once at server boot. Ledger reads and later dispositions remain
Shikigami-owned; workflow and session reads use their owning libraries. A replay
does not promise that execution succeeded; the lifecycle resource supplies that
separate fact. Ledger retention must preserve idempotency for the retry horizon.

## References

[ExecPlan 90](../plans/90-accept-addressed-agent-runs-over-http-with-server-owned-idempotency.md),
[ADR 0021](0021-operator-verbs-wrap-the-owning-library.md), and
[ADR 0022](0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md).
