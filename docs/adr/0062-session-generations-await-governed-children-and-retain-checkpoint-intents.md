# 0062. Session generations await governed children and retain checkpoint intents

Date: 2026-10-28

Status: accepted

## Context

An idle continuing worker must survive without polling or exhausting its
coordinator's journal. Accepted assignments need distinct delegated children,
while a crash between child completion and result notification must preserve
the same accepted result. Checkpoint integration has a separate owner and can
commit before its acknowledgement arrives.

## Decision

The new `shikigami.worker-session` workflow restores its carried seed before
static generation labels. One generation drives at most one assignment through
the existing governed delegation boundary. The session's durable mapping is
recorded before spawn. A registered child is reattached through its retained
parent relationship; replay does not resolve a different target or reserve
another descendant. New spawns recheck current objective revisions, owner,
epoch, root, cutoff and target identity. Missing objective providers fail closed.
Explicit model requirements and inherited permissions reach normal agent-run
admission. Existing one-shot delegation keeps its original request shape.

Idle, parked and unresolved sessions wait on a generation-owned awakeable.
Publishing that reference is a checked session write. Message acceptance and
other progress notifications complete the published awakeable and append to its
fixed journal generation in the same transaction as the accepted store change.
A rotated generation never redirects an old wake to a successor. Duplicate
accepted commands return their original acknowledgement without waking a later
generation. Active child completion drives the next generation; its unused
mailbox wake is cancelled.

Assignment start selects at most three prior committed results. Each selection
retains its result receipt and includes the output only when its encoded size
is at most 8 KiB. The selected context is protected and fixed with the child
mapping before spawn. A later generation reads that selection rather than
performing relevance search or copying an entire parent history.

Checkpoint integration first persists an immutable intent for up to 100
contiguous retained events. A pending pointer prevents overlapping batches and
local cursor bypass. The external owner must deduplicate the operation before
checking the expected objective/assignment/criteria revision and owner epoch;
it must also enforce fresh exact action authorization at its protected boundary.
Unknown transport outcomes preserve the intent. Retry sends the identical
request. Only a receipt bound to its objective, operation, fingerprint and
advancing version permits local progress and cursor acceptance in one checked
transaction. A local integration fault preserves the pending intent even when
the external owner has already committed. A duplicate accepted receipt skips
the local integration callback.

The objective provider exposes a package-private, process-local rejection authority
only after reading an exact immutable non-commit under current permission. It has no
wire decoder. Explicit checkpoint reconciliation requires this authority plus a
parent decision naming the objective, assignment and criteria revisions and a bounded
revalidation statement. Unknown and accepted outcomes cannot produce that authority.

The checked `SupersedeSessionCheckpoint` command retains the old intent and rejection,
stores the parent decision and replacement in a protected audit payload, publishes the
new pending intent and a `CheckpointSuperseded` session event atomically. It never
advances the consumed cursor. The audit notification is a separate later source fact.
Its command receipt recovers the original replacement before consulting changed
provider configuration or versions. New integration calls recover the active retained
intent; a known caller operation still recovers its own original request first.

Session runtime checkpoint callbacks are factories scoped to the retained parent
identity. Public provider records and existing intent/receipt codecs remain unchanged.
The new native lifecycle event preserves all old event interpretations; its regenerated
fold fingerprint intentionally invalidates old aggregate snapshots for reconstruction.
No workflow step shape changes. Fresh worker-tool schemas expose reconciliation, while
preparation retains an older accepted schema and its original closed command set.

The checkpoint types are a consumer adapter contract. They neither select nor
implement the separately owned IR-13 task store. Plan 99 qualifies objective-backed checkpoint and ownership adapters; retained coordination scopes and production composition remain separate acceptance. Deterministic fence adapters prove only the objective-side protocol and never workspace containment.

## Alternatives rejected

Polling an idle session would spend work without new evidence. Signalling a
current generation discovered after rotation would let stale delivery wake
unrelated work. Reconstructing context from the latest parent history would
change an accepted assignment after restart. Retrying checkpoint integration
with a new operation or current snapshot could duplicate an already committed
update or conceal an unresolved one.

## Consequences

Session journals stay bounded by assignment generations. Protected context and
pending intents outlive workflow generations and terminal-child GC. A stale
checkpoint conflict remains visible and requires explicit reconciliation.
Ownership transfer must account for pending checkpoint intents and old child
effects before establishing a successor; lease expiry supplies no such proof.
Existing agent/conversation journal branches and result codecs are retained.

## References

- [Plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md)
- [ADR 0061](0061-continuing-sessions-own-ordered-assignments-and-retained-receipts.md)
- [ADR 0023](0023-delegation-is-governed-at-the-child-spawn-boundary.md)
- [Workflow versioning](../workflow-versioning.md)
- [IR-13](../improvement-requests/support-optional-major-task-tracking.md)
