# 0061. Continuing sessions own ordered assignments and retained receipts

Date: 2026-11-04

Status: accepted

## Context

A continuing worker must retain accepted follow-ups and completed findings even
when its coordinator restarts or a result notification is lost. Kioku memory,
Danwa conversation completion and a one-shot delegated workflow do not own that
mailbox. Reusing a logical worker key as a delegation key would also reuse its
first child, because delegated child identity excludes the parent's generation.

## Decision

A checked `WorkerSessionLifecycle` aggregate owns an ordered mailbox, immutable
command acknowledgements, assignment mappings, retained results and event
cursors. Its live projection writes those application-owned rows in the same
transaction as the accepted lifecycle event. Instructions, frozen delegation
input and result bodies live in a separate protected payload table. Ordinary
inspection returns bounded metadata and references. Protected reads require a
fresh, short-lived access grant for the admitted parent or current worker;
control writes belong to the admitted parent.

Find-or-create scope binds the recorded parent identity, recorded worker
identity, parent scope and stable worker key. Objective, root and admission
limits are immutable bindings, so retrying creation with changed settings cannot
reset limits or replace an objective. Each accepted message receives a sequence
and an assignment ID. Child identity derives from the retained session, target
and assignment ID through the existing delegation identity function. The store
fixes that mapping before spawn; callers cannot supply another child ID.

Command operation keys bind immutable payload fingerprints and owner epochs.
Identical retries return the original receipt even after progress advances;
conflicting reuse refuses. A losing optimistic revision race may retry the same
key at the new revision. Result acceptance stores the protected result,
assignment completion, correlated event and prepared generation-bound wakes in
one checked transaction. Notifications are hints. A crash after that commit can
precede consumer integration, but cannot leave a committed result without its
prepared wake publication. Recovery qualification targets the unconsumed result
cursor at that actual boundary; it never splits the owner transaction to create
a synthetic notification gap.
Local progress integration and event-cursor advancement share one transaction;
an external checkpoint owner requires its own pending-intent protocol.

Parking and unresolved observations retain the active assignment and child.
They do not establish that an external effect ended or grant renewed write
authority. Closure requires an idle session with no queued assignments.
`Failed` and `Cancelled` are logically closed but remain nonterminal in the
aggregate solely to acknowledge retained events; they accept no new work.
Successful assignments leave the session idle and available for follow-ups.

The store is an internal persistence boundary, not a public result-submission
API. Runtime orchestration must establish the real child result and fresh
authority. Objective references in this layer identify the separately owned
provider; they do not implement objective revisions or workspace fences.

Continuing-session coordinates and commitments retain separate nominal scopes.
Provider/objective locators, parent scope and worker slot stay distinct through
admission. Assignment identities decode as canonical RFC 4122 UUIDv5 values;
artifact references preserve the provider's exact spelling. Paging limits,
workflow generations, provider receipts and objective activity retain their own
types and original numeric/string/boolean codecs. Child and coordinator workflow
references stay native until SQL or JSON adapters.

The mapped WorkerSessionId is deliberately a total Text carrier, as required by
Keiro's nominal binding contract, including its empty initial state. Its private
representation has no Generic construction. The admitted binding decoder checks
that the session identity equals the original UUIDv5 derivation from its retained
scope commitment. The generated carrier codec is not admission authority. Retained
scope corruption or a different valid digest is an owning binding refusal with
transaction rollback; restoring the original bytes restores the original session.

## Alternatives rejected

Using memory search as a mailbox would lose ordering and deduplication truth.
Re-keying a session after coordinator rotation would abandon accepted work.
Committing results separately from events would make notification failures
indistinguishable from missing results. Terminalizing the aggregate would
prevent a coordinator from acknowledging its final retained event.

## Consequences

The session catalog adds a distinct live-only projection group whose protected
payloads cannot be reconstructed from public lifecycle metadata. Retention must
preserve idle sessions, payloads and command receipts independently of workflow
GC. Real IR-11 fencing and IR-13 checkpoint providers remain explicit plan-84
completion gates; deterministic store fixtures do not satisfy them.

## References

- [Plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md)
- [Plan 86](../plans/86-qualify-integrated-adaptive-autonomous-delivery.md)
- [ADR 0022](0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md)
- [ADR 0023](0023-delegation-is-governed-at-the-child-spawn-boundary.md)
- [ADR 0033](0033-recorded-agent-principals-key-durable-state.md)
