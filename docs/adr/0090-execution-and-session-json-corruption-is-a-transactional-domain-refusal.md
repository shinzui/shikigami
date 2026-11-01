# 0090. Execution and session JSON corruption is a transactional domain refusal

Date: 2026-10-31

Status: accepted

## Context

Two real PostgreSQL controls put an invalid digest inside an execution snapshot
reference and a session admission reference. Their reads returned
ExecutionStorageUnavailable and SessionStorageUnavailable. The three existing
malformed-data controls passed. The body-table metadata correction in ADR-89 did
not cover these separate retained JSON rows.

Both owners used Hasql decoder refinement to run FromJSON. A rejected domain
value became a query decoding error and entered the generic store-failure path.
This disguised persistent corruption as a potentially transient availability
failure. More private checked scalars would make that distinction increasingly
important across retained operations, attempts and session receipts.

## Decision

Execution.Store and WorkerSession.Store capture owned JSON decoding as an
`Either () value` row result. Keep the expected domain type in each SQL statement;
do not erase it to an unconstrained JSON value at application call sites. The
unit error carries no protected source text or parser diagnostic.

Each owner traverses these results inside its transaction and aborts malformed
rows with CorruptReplay or SessionBindingConflict. The execution precondition
adapter uses the same read path. Optional and bounded-list results preserve
missing-row behavior, order, limits and row locks. Genuine database transport
failures still pass through the existing native query/store error handling.

Use the established transaction abort mechanism. Do not put deferred throwing
values inside a successful SQL decoder: evaluation after commit must not decide
whether a write should have rolled back. Keep native read-model guards, command
preconditions, authorization and protected-body rechecks in place.

The custom payload-body metadata decoder remains the ADR-89 boundary. The session
command-receipt decoder already classifies its own raw JSON explicitly and keeps
that ownership. This decision covers these two stores; it does not certify every
other application's metadata decoder.

## Alternatives rejected

Reclassifying every store error as corruption would hide real outages. Matching
rendered driver error text would couple domain semantics to diagnostics. Returning
raw JSON throughout store code would discard the statement's domain contract.
Throwing from a decoded value thunk risks crossing the commit boundary. Decoding
after a successful transaction is too late for coupled writes and receipts.

## Consequences

Valid persisted JSON, native command values, query results and public codecs do
not change. Corrupt retained references now produce explicit domain refusals.
Regression controls cover reads and attempted mutations, unchanged native stream
versions and unchanged session message/command/payload counts. Same-build recovery,
late-write rollback and transport-outage tests remain required. No historical
reader or populated cross-build replay promise is introduced.

## Closed format selectors

ExecPlan 108 retains execution, attempt, harness, replay-result, compliance-fact
and worker-session format selectors as `FormatVersion scope`. The closed `V1`
value has a nominal protocol scope, no arithmetic or Generic instance, and the
same JSON number `1` as the former integer field. This prevents an unsupported
version from being constructed inside a successful typed record. A future
protocol version requires an explicit owning-format change; another protocol's
selector cannot be substituted or coerced into this one.

Unsupported versions are injected into complete encoded fixtures rather than
constructed as typed records. The execution metadata reader and worker-session
terminal scan must still return their owning corruption refusal and condemn the
transaction, including when the caller ignores that refusal and writes both
before and after it. Restoring the exact original JSON must recover the original
state without a replacement operation or assignment. The existing replay-context
protocol that accepts versions 1 and 2 keeps its separate admission contract.

## References

[ADR-53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md),
[ADR-89](0089-protected-payload-references-retain-checked-units.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
[the failed controls](../evidence/keiro-0.22/json-row-before-regressions.txt),
[the acceptance record](../evidence/keiro-0.22/json-row-results.txt),
and the public store boundary at `mori://shinzui/kiroku/packages/kiroku-store`.
The native guarded-query owner is `mori://shinzui/keiro`, at
`keiro/src/Keiro/ReadModel.hs`; its artifact-level source URI is pending.
