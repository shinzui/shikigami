# 0099. Assignment call readers preserve corruption and transaction ownership

Date: 2026-10-31

Status: accepted

## Context

The assignment-local selection ledger owns actual-call receipts, limits and held
usage. It shares transactions with resource accounting but can also operate
without a root. Its assignment, individual-call and bounded-list readers still
used SQL decoder refinement for owned JSON after ADR-98 corrected the separate
resource owner. An invalid fact must not disappear from inspection or look like
an empty/unavailable ledger.

## Decision

SelectionStore captures owned JSON as Either () value in statements retaining
their expected domain type. A shared reader traverses the complete optional or
bounded-list result inside the transaction. On decoding failure it condemns that
transaction and returns the owning CallStateCorrupt refusal. It carries no parser
or source text. Genuine SQL/connection failures remain the outer StoreError.
Root corruption keeps the separate resource owner's CallResourcesRefused value.

Admission, finish and reconciliation propagate assignment and individual-call
refusals in their existing read order before publishing successful state. No
invalid list member is omitted. A read boundary condemns even when its usual
caller only inspects: a coupled caller may already have written another root or
receipt. Native/resource abort ownership remains intact.

inspectSelection now returns an explicit Either for the ledger refusal around
its optional bounded result. Missing history retains Right Nothing. The CLI
inspector preserves three outcomes: outer store failure is unavailable, owning
data refusal is refused with its bounded error code, and absent valid history
has zero attempts. Valid public descriptors/facts/counters keep their existing
JSON fields and values. A malformed row cannot become zero attempts or a partial
facts set.

Queries, parameters, assignment/root lock order, the 100-fact inspection bound,
ordinal order, retry/resource ceilings and settlement convergence are unchanged.
The first-release Haskell callers adopt the explicit inspection result; no legacy
reader is introduced. No workflow labels, order, effects or valid retained codecs
change, and this correction needs no patch.

## Alternatives rejected

Keeping refinement failures in StoreError loses the data/availability distinction.
Dropping a malformed call can hide unresolved spending. Returning Left after
commit, or without condemnation after earlier writes, permits partial accounting.
Mapping every failure to corruption would hide real SQL and connection failures.
Using the resource corruption code for an independent assignment ledger would
confuse their ownership.

## Consequences

Positive PostgreSQL admissions create two valid calls before corrupting an
assignment or one call. Inspection, admission, completion and reconciliation
refuse without changing root holds. A valid second call detects silent omission.
A coupled tentative root publication rolls back when completion encounters that
bad row. SQL-failure controls remain a separate outer-store outcome.

Other workspace/objective/directory/ledger readers and model/other decision values
still require their own audit. This decision does not certify their decoders,
the complete scalar/identity census or packaged/Linux runtime behavior.

## References

- [ADR-53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md)
- [ADR-90](0090-execution-and-session-json-corruption-is-a-transactional-domain-refusal.md)
- [ADR-98](0098-resource-row-decoding-refuses-corruption-inside-the-transaction.md)
- [Plan107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md)
- Public transaction owner: `mori://shinzui/kiroku/packages/kiroku-store`.
