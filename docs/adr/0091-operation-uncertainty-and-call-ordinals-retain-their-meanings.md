# 0091. Operation uncertainty and call ordinals retain their meanings

Date: 2026-10-31

Status: accepted

## Context

An operation's persisted uncertainty flag was a Bool despite controlling retry,
reconciliation and advancement. A selection receipt's ordinal used the same
AttemptCount type as the assignment's observed call count. The receipt decoder
required a positive signed-int64 ordinal, but its public constructor admitted the
count's zero initial value. Domain APIs did not retain that distinction.

## Decision

OperationUncertainty is a closed choice: NotMarkedUncertain or MarkedUncertain.
The persisted `uncertain` field retains false/true JSON. NotMarkedUncertain includes
reserved or in-flight work; it does not assert successful completion. Outcome,
attempt and late-receipt records retain their existing authority. Dispatch,
recovery, reconciliation and advancement use the explicit alternatives.

CallOrdinal is private, positive and bounded by signed int64, with numeric JSON
and no Generic, Num, Integral, IsString or enumeration construction. It is distinct
from AttemptCount `selection-calls`, whose initial value is zero. Construct the
next ordinal with a checked operation before resource admission; an exhausted
range keeps AssignmentCallLimitExceeded and its existing refusal priority.

Receipt fields and SQL writes retain CallOrdinal. The counter owner supplies an
explicit conversion to the observed selection count. Only real SQL and evidence
SDK adapters render its primitive value. The complete receipt retains its JSON
fields and primitive ordinal bytes. Existing zero/negative/overflow JSON rejection
moves from the whole receipt decoder into the private scalar reader.

## Alternatives rejected

A raw Bool permits cancellation, overage and uncertainty to share an accidental
representation inside domain interfaces. Calling the false alternative a known
successful outcome would claim more than the existing state proves. Reusing the
zero-based observed count for a one-based receipt position leaves invalid public
construction available. A numeric instance or Generic parser would reopen that
boundary. Unchecked int64 narrowing would move overflow into persistence.

## Consequences

Valid operation booleans, receipt numbers, native commands and action identities
remain unchanged. No workflow shape, schema, identity allocation or native fold
change is intended. Complete operation codecs cover both boolean values; complete
accepted receipt bytes use primitive ordinal 1 before negative cases. Scalar and
compiler controls cover the bounds and prevent substitution or unchecked
construction. Same-build dispatch, recovery, accounting and late-receipt evidence
remain mandatory. This closes two values, not the complete scalar/identity audit.

## References

[ADR-53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md),
[ADR-54](0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md),
[ADR-77](0077-attempt-counters-and-call-ceilings-retain-their-scopes.md),
[ADR-82](0082-root-control-decisions-and-execution-termination-have-distinct-types.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
[the acceptance record](../evidence/keiro-0.22/execution-values-results.txt),
and [the scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
