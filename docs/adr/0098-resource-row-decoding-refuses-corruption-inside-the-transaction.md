# 0098. Resource row decoding refuses corruption inside the transaction

Date: 2026-10-31

Status: accepted

## Context

ADR-90 separates retained JSON corruption from database availability failures in
execution and session stores. Resource accounting remained a different owner:
its root, operation, attempt and allocation statements used Hasql refinement to
run FromJSON. Five real PostgreSQL controls against the committed decoder fail
through the store-error path instead of returning the resource owner's refusal.

Moving decoding out of Hasql's query-failure path also removes its automatic
transaction failure. A typed Left alone would allow a coupled caller to commit
tentative writes. Resource accounting participates in the atomic execution and
delegation boundaries governed by ADR-53.

## Decision

ResourcesStore statements retain the expected domain type while capturing each
JSON result as Either () value. The unit error carries no parser diagnostic or
source JSON. The owner traverses the optional result inside the transaction,
condemns the whole transaction on decoding failure and returns ResourceStateCorrupt.
Genuine SQL/connection failures remain StoreError; no error-text matching or global
store-error reclassification is introduced.

Every root/operation/attempt/allocation reader uses that checked path. Root
callbacks, scope lookup, allocation updates and attempted settlement propagate
the refusal before further successful publication. Decoding never returns a
successful value containing a deferred exception. Invalid rows are never omitted.
Optional absence retains its existing missing-row behavior; valid queries,
parameters, row locks, serialization, guards and accounting updates are unchanged.

Condemnation belongs to the read boundary even when the read itself is normally
read-only. A caller may already have written another root, operation or receipt
in the same transaction. Returning data does not authorize that caller to commit
partial state, and condemnation remains effective if the caller mishandles Left.
Existing native command aborts and protected-payload checks retain their owners.

## Alternatives rejected

Treating every store failure as corruption hides outages. Leaving domain JSON
validation in a SQL refinement mislabels malformed retained values as availability
failures. Decoding after commit cannot roll back coupled writes. Throwing from a
lazy decoded value makes transaction behavior depend on later evaluation. Dropping
a malformed attempt or allocation can lose an active or exclusive accounting hold.

## Consequences

Valid stored JSON and public resource interfaces retain their bytes and behavior.
Malformed JSON/refined values now produce an owning data refusal. This change does
not replace business consistency checks with JSON decoding, relax resource caps,
refund uncertain spending or certify every other store's decoder.

Regression controls first establish valid rows, then inject malformed metadata in
a task-owned fresh database. They cover all four row families, unchanged active/
held accounting, rollback of a coupled tentative root publication and rollback
of an earlier batch member. The same five cases fail against the committed
pre-change decoder. Existing publication SQL-fault, uncertainty, conservation,
revision and dispatch-fence controls remain required.

Model/other decision values, the complete scalar/identity census and remaining
store decoder owners keep plan107 open. No packaged runtime or Linux qualification
is inferred from these database tests.

## References

- [ADR-53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md)
- [ADR-90](0090-execution-and-session-json-corruption-is-a-transactional-domain-refusal.md)
- [ADR-94](0094-accounting-entities-use-allocated-identities-and-root-origin-receipts.md)
- [Plan107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md)
- Public transaction owner: `mori://shinzui/kiroku/packages/kiroku-store`.
