# 0076. Resource amounts are checked before accounting publication

Date: 2026-10-30

Status: accepted

## Context

Resource vectors and finite limits used Integer, with the same nonnegative int64
rule repeated at admission and settlement. Addition and subtraction could create
out-of-range candidates, and known-counter accumulation was not checked together
with every counter it recorded. A constructor call could also supply a negative
amount before the transaction discovered it. These are domain enforcement values,
not merely persistence DTOs.

Baikai reports Natural token totals and exact Rational costs. Its native evidence
keeps absent, inconsistent and estimated observations distinct from invoice facts.
The ledger's finite integer domain cannot represent every upstream observation.
This remains true even for an explicitly unbounded admission policy: unbounded
permission does not change the ledger's representation.

## Decision

Use a private ResourceAmount with a checked parser for 0 through int64 maximum.
JSON decoding invokes that parser, and valid values retain their exact numeric
bytes. Finite limits, held/settled/known vectors, operation/attempt reservations,
measurements and root active-limit controls retain the checked type. A quantity
vector pairs its closed Dimension keys with these amounts; the amount alone does
not claim a physical unit independently of its dimension. Cost remains integer
millionths of one USD. Add no Num, Integral, IsString or Generic escape hatch.

Named vector addition/subtraction return typed failure on overflow or underflow.
Signed, unbounded intermediates are local calculations, never published amounts.
Admission preserves its existing dimension/finite-limit refusal order before the
aggregate overflow check. Narrowing cannot refund spent or held work. Prepare
known-counter and scope-usage results before writing the root, attempt or allocation.
Retain the existing root lock order and late projection/accounting exceptions
that abort the enclosing transaction under ADR-53.

At the provider adapter, an out-of-range observation remains an unknown billing
dimension. It cannot become zero usage or release that dimension's held ceiling.
A terminal transport may release active capacity while billing stays unresolved,
using the existing PartialUsage protocol. Valid observations settle exactly;
estimated model prices still do not become provider invoice facts. Do not alter the
provider response or existing protected replay/evidence records to invent a smaller
measurement.

## Alternatives rejected

A Num instance recreates unchecked arithmetic. Clamping or replacing an invalid
measurement with zero silently refunds work. Treating unbounded policy as
unbounded storage changes the declared ledger contract. Returning a business Left
after tentative coupled writes instead of preserving late rollback exceptions
would split lifecycle, protected payload and accounting state.

## Consequences

Scalar constructors and codecs own amount validation once. Arithmetic additionally
checks the result, while policy/authority/aggregate consistency checks remain in
their existing transaction. The service operator view can expose an invalid
occupancy refusal instead of treating an invalid sum as available capacity.

Tests compare positive numeric codecs before rejecting invalid values, exercise
checked debit and refusal priority, and use the actual HTTP provider path to
compare a valid token report with an out-of-range report. A synthetic full counter
in an isolated application table qualifies settlement refusal without changing the
root or accepted attempt. This is a boundary test, not a claim to have generated
int64-maximum histories. Scope-specific call/session counters and the wider domain
scalar census remain separate work; this record does not exempt their primitives.

## References

[ADR-53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md),
[ADR-74](0074-domain-state-revisions-keep-their-scope-at-application-boundaries.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
[the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids),
and [Baikai evidence semantics](mori://shinzui/baikai/docs/model-call-evidence).
Source ownership is `mori://shinzui/baikai`, project-relative paths
`baikai/src/Baikai/Cost.hs` and `baikai/src/Baikai/Usage.hs`;
artifact-level source URIs are pending.
