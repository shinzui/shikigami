# 0067. Objective checkpoints use assignment-scoped preconditions

Date: 2026-10-29

Status: accepted; persistence and checkpoint/ownership adapters implemented; production wiring pending plan 99 milestone 3

## Context

Public objective commands edit a shared record, while continuing workers routinely
checkpoint independent assignments concurrently. Requiring the same objective revision
for both paths would turn sibling progress into a reconciliation requirement. The
existing `ObjectiveVersion` carries assignment and criteria revisions, but no expected
instruction revision. Ignoring instruction changes would accept results under stale
meaning, contrary to the recovery requirements of UC-1.

## Decision

One command executor owns authentication, current authorization, receipt lookup,
precondition validation and atomic persistence. Its closed command constructor selects
the preconditions; public callers cannot choose a weaker validation mode.

Public mutations and ownership transfers require exact objective revision equality.
Internal checkpoint ingestion requires matching assignment revision, criteria revision,
owner, epoch, root and active flag. Its expected objective revision is an ordering base
that cannot exceed the current revision. The executor locks the objective, validates
these conditions and allocates the next revision from current state in one transaction.
Two sibling checkpoints can therefore commit with distinct increasing receipts. Session
binding, source-event authenticity, contiguous cursors and current authority remain
required independently of these version checks.

An accepted objective instruction change advances every existing assignment revision
atomically. Objective status transitions do likewise. Returning instructions or status
to an earlier value never restores old revision numbers. Assignment IDs and counters
are never reused or reset. Criteria revisions retain their independent check. This
preserves the existing checkpoint codec and fingerprint while invalidating stale work.

Authorized identical accepted retries return their retained receipts before version
validation. A definitive non-commit outcome remains immutable; an uncertain transport
outcome is not rejection. Explicit reconciliation retains the original intent and
revalidates its evidence before preparing a new operation.

The production adapters are actor-scoped closures. Resolving a worker reference checks
its canonical assignment commitment and current coordination permission. Current
versions inspect the original resource root and use the earlier of its cutoff and
the assignment cutoff. Accepted retries do not require the source or fence provider
to be available again.

Session operation keys are scoped by session, whereas objective command receipts are
scoped by objective. The adapter derives its objective-side key from the source
session and operation together, with separate versioned namespaces for checkpoints
and handoffs. Consumer receipts retain their original operation and fingerprint.
Two siblings may use the same session-local key without colliding at the objective.

A checkpoint command fingerprints the immutable intent. The owner derives result
observations inside its inspection and commit transactions, validating the retained
session binding, parent actor, exact event bodies, physical cursors and result
commitments. Missing or corrupt source facts produce uncertainty without retaining
a non-commit proof. An execution with unresolved effects remains pending until its
owner settles them. Only an exact persisted non-commit outcome becomes a consumer
conflict. Ownership commands similarly fingerprint the full intent and fence, check
the session owner's retained source in the commit transaction, and require the
configured workspace provider's settled proof before fresh transfer.

## Alternatives rejected

Whole-objective equality for checkpoints makes independent progress conflict. Omitting
instruction validation accepts stale meaning. Adding an instruction field to the durable
checkpoint codec is unnecessary when the existing assignment revision can represent
invalidation. A second provider executor would duplicate authorization and receipt rules.

## Consequences

Instruction and status changes update the bounded assignment graph under the objective
lock. The graph must remain bounded as planned. Store and provider tests must prove
sibling commits, public conflicts, instruction-only invalidation, reverted-instruction
invalidation and accepted-receipt recovery after later changes. Plan 98 now supplies those store tests using real worker-session results and retained intents. An inactive flag is an equality precondition, not a requirement that the flag be true: newly prepared intents can reconcile previously accepted results after cancellation, while fresh work remains denied. Plan 99 now exercises these rules through the real session integrator and objective adapters, including a lost acknowledgement followed by local cursor failure. Production composition and explicit rejected-intent reconciliation remain its milestone 3. Deterministic fence fixtures qualify only the objective/session protocol, not workspace containment.

## References

- [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md)
- [Plan 98](../plans/98-persist-authoritative-objectives-and-conditional-commands.md)
- [Plan 99](../plans/99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md)
- [ADR 0062](0062-session-generations-await-governed-children-and-retain-checkpoint-intents.md)
- [ADR 0063](0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md)
