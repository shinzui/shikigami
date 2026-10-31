# 0082. Root control decisions and execution termination have distinct types

Date: 2026-10-30

Status: accepted

## Context

A root's cancellation decision and recorded budget overage both used Bool.
setRootControl and stopExecution also accepted booleans with different meanings.
Those fields and arguments could substitute for one another despite selecting
different admission rules and native terminal commands.

These are domain decisions. Incidental comparison results remain ordinary
booleans; the retained decisions and public domain command choices need their
own types.

## Decision

Use Cancellation (ContinueWork or StopWork) for root control, and Overage
(NoOverage or OverageDetected) for the retained overage observation. Both keep
their exact existing boolean JSON representation, including direct encoding.
The root codec still accepts the same boolean values and rejects other JSON types.

setRootControl accepts Cancellation. Cancellation stays irreversible. Overage
stays latched: a newly exceeded measurement records OverageDetected; otherwise
retain the previous observation. Settlement and receipt draining remain permitted
after cancellation, cutoff or policy revision changes. No accounting, capacity or
transaction rule changes.

stopExecution accepts a separate Termination choice (StopAsFailure or
StopAsCancelled). The driver explicitly maps the observed root decision or other
failure to that choice. The local branch predicate selects the same generated
commands, pre-inline root check and terminal phase as before. Termination has no
journal or wire codec; it is a command argument, not a new persisted field.

## Alternatives rejected

Retaining booleans permits cancellation/overage/termination substitution. Sharing
one enum still erases those meanings. Encoding enum constructor names would change
the persisted root protocol without need. Clearing overage on a later smaller
measurement or allowing cancellation to reverse would change the resource contract.

## Consequences

The compiler rejects mixing the three concepts. Complete root controls cover both
boolean wire states and exact encoded bytes before existing counter refusals.
Existing irreversible-cancellation, sticky-overage, post-cancellation settlement,
driver stop, workspace freeze and accepted-process cases exercise the same owners.
No step name, order, result codec, DSL declaration, identity derivation or native
fold changes. The complete scalar/identity census and final profile qualification
remain separate work.

## References

[ADR-53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md),
[ADR-77](0077-attempt-counters-and-call-ceilings-retain-their-scopes.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
and [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
