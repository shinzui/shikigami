# 0077. Attempt counters and call ceilings retain their scopes

Date: 2026-10-30

Status: accepted

## Context

Root active attempts, unresolved billing counts, assignment calls and assignment
capacity shared Integer. A field from another scope could satisfy an API or
arithmetic expression accidentally. Subtraction could publish a negative counter
when retained accounting was inconsistent. Call, retry and concurrency ceilings
were also freely interchangeable, and profile-to-runtime conversion did not refine
them into nominal operational values.

These are domain decisions. They are distinct from incidental local indexes,
database COUNT results and the signed profile's canonical wire representation.
Their valid persisted representation remains a JSON number.

## Decision

Use private AttemptCount scope values for nonnegative observed attempt counts.
The type role is nominal. Root-active and root-unknown are distinct; selection
calls, active attempts and unknown billing retain separate selection scopes.
Assignment call ordinals retain the selection-call count scope. Their persisted
receipt decoder additionally checks positive int64 ordinals, and the call writer
retains its existing int64 admission bound before incrementing.

Use private AttemptLimit scope values for finite int64 call, retry and concurrency
ceilings. Counter/limit comparisons require matching scopes. Token ceilings retain
ResourceAmount. No Num, Integral, IsString or Generic instance exposes primitive
arithmetic or representation coercion. Constructors/codecs reject negative values;
finite-limit codecs also enforce their upper bound. Observed counts are naturals;
each storage owner retains its own finite writer bound.

Refine the signed profile's primitive wire limits once into operational CallLimits.
The factory returns typed failure, including for a negative duration, without
falling back to permissive defaults. Provider preparation, private registry setup
and prepared-call admission propagate that failure. Their JSON field names and
valid numeric bytes remain unchanged. No dependency codec or signed profile digest
is rewritten by this operational conversion.

Decrement is checked. Prepare both root and assignment count results before
settling coupled root/assignment/call state. An inconsistent zero refuses without
changing any participant. Keep late accounting/projection failures as rollback
exceptions where the execution owner has already written tentative state under
ADR-53. The new Either operations do not authorize committing a partial result.

Database COUNT values and native SDK evidence ordinals convert explicitly at
their adapters. The next retry index uses the operation's prior call count and
compares it with the retry ceiling; no integer increment of a bounded limit is
needed. Test-only cross-root count summaries unwrap explicitly. The Linux fixture
checks active and unknown holds separately instead of adding unrelated scopes.

## Alternatives rejected

Deriving Num preserves accidental interchange and unchecked subtraction. Sharing
one unscoped wrapper hides which owner or kind of count it represents. Treating
invalid limits as absent widens permission. Clamping a negative count to zero
conceals inconsistent retained accounting and can release capacity prematurely.

## Consequences

The compiler rejects root-active/root-unknown and call/concurrency substitutions.
Positive codec controls precede invalid input checks. Isolated application-table
boundary seeds test active/unknown underflow for roots and assignments, requiring
unchanged root, assignment and accepted receipts. They are not real negative-count
histories or edits to framework journals. Existing concurrent retry, lost-response,
unknown billing and late-settlement fixtures continue to exercise the actual owners.

Execution model-turn/repair/receipt counters, other policy values and the wider
scalar/identity census remain separate work. This decision does not label every
serialized domain record a wire DTO or claim the full census is complete.

## References

[ADR-53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md),
[ADR-74](0074-domain-state-revisions-keep-their-scope-at-application-boundaries.md),
[ADR-76](0076-resource-amounts-are-checked-before-accounting-publication.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
and [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
