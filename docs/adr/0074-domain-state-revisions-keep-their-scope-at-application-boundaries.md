# 0074. Domain state revisions keep their scope at application boundaries

Date: 2026-10-30

Status: accepted

## Context

Objective state, assignment state, instruction revisions, criteria revisions and
worker owner epochs previously shared Integer. A call could substitute one for
another without a compiler error. The values are serialized as JSON numbers and
participate in retained receipt fingerprints, so gaining nominal safety must not
change valid serialized values or move authority checks outside their transactions.
Repository.Revision already names a different concept: a pinned Git commit hash.

## Decision

Use an abstract `StateRevision scope` for nonnegative state counters. Its scope
has a nominal type role, and the constructor is private. Parse at input boundaries;
inside the domain use the scoped value and explicit initial/advance operations.
Expose no Num, IsString or Generic instance. Ordinary coercion cannot change a
scope or construct an unchecked counter from Integer. Keep repository Git revisions
in their existing separate type.

Domain command APIs retain the same scope as the state they address. In particular,
objective expected revisions and worker-owner epochs are distinct types. Render
numbers explicitly at owning generated and database adapters. Objective-version,
checkpoint and ownership provider contracts retain scoped values as domain
interfaces, including worker-session state revisions and worker-owner epochs.
Resource-root policy revisions also retain their own execution-root scope across
reservation, attempt, allocation and control APIs. Workspace requests, admissions, retained controls, handoff fences and private RPC
requests use that same worker-owner scope; only the SQL parameter codec renders
it as an integer.
Those adapters do not widen authority: current membership, expected state, owner
and lifecycle fences still execute in the production transaction. Preserve late
projection/accounting exceptions that cause complete rollback under ADR-53.

Mailbox sequences and event cursors use distinct worker-message and worker-event
scopes, including Flow waits and checkpoint providers. Assignment pagination has
an abstract MessagePosition with its own before-first sentinel; an event cursor
cannot receive -1. Preserve the public after wire field even where the Haskell
field name must differ. Refuse a new event append at the existing stored cursor
limit inside the same transaction, preserving payload/receipt/event rollback and
readability of the retained state. This does not authorize truncation or rotation.

JSON encoding remains an integer with identical bytes for valid values. No scope
tag is added to a journal or request. Malformed negative counters fail decoding
rather than entering domain state. Existing finite database bounds remain checked
at the writer. This first-release type correction does not imply a deployed schema
upgrade or authorize resetting a developer database.

## Consequences

The compiler rejects accidental substitution among revision domains. Boundary code
performs visible conversion, while business transitions cannot perform arbitrary
numeric arithmetic. `previousRevision` returns Nothing at zero, so a predecessor
lookup cannot fabricate a negative epoch. The operator parser refines numeric
revision/epoch flags before runtime IO. Tests must establish a working compiled client before accepting
negative compilation cases, and must retain numeric JSON/byte compatibility and
transaction/receipt recovery evidence. Additional domain scalar findings remain
subject to their own complete review; this decision is not a blanket claim that
all primitive fields are boundary DTOs.

## References

[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
[ADR 53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md),
[ADR 73](0073-objective-identity-is-allocated-and-creation-receipts-own-deduplication.md), and
[the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
