# 0063. Handoffs establish epochs only after fences and versioned owner receipts

Date: 2026-10-28

Status: accepted

## Context

A continuing worker can retain accepted findings while a validation process or
tool mutation is still in flight. A session lease, child cancellation marker or
idle notification cannot prove that the old writer stopped. Ownership also
appears in the separately owned objective checkpoint, so a lost acknowledgement
must not cause a second transfer or restore an old owner.

## Decision

A transfer is an immutable, deduplicated request binding the retained session,
parent actor, objective version, root, workspace resource, old owner/epoch and
successor identity/name/epoch. The session enters `Transferring`, preserving its
mailbox, active assignment, artifacts and resource limits. No new assignment
starts in that state. An already accepted assignment may record its result
without completing the transfer. The admitted parent controls reconciliation.

The workspace owner must fence the former writer and reconcile all operations
and processes belonging to the session, including permitted descendants. Its
settled proof binds the entire transfer and exact resource. Unknown completion
remains unresolved. A real write requires fresh current-session authority and
the workspace owner's conditional epoch/operation check at the protected effect
boundary. Checking an epoch once before an uncontrolled process starts is not
sufficient; such a process remains in flight until the owner can reconcile it.

The session retains the settled fence proof before calling the objective owner.
It waits for the active assignment to finish and for retained execution
references to show terminal logical progress with no pending transport receipts.
Missing or unresolved execution evidence blocks establishment. The objective
owner deduplicates the transfer before optimistic validation and atomically
updates its owner and epoch while retaining accepted evidence. A stale
checkpoint update conflicts rather than restoring the former owner.

Only a matching versioned ownership receipt and the retained settled proof
permit the checked local transaction to establish the successor. That
transaction advances the epoch, changes the target identity/name and records
the established event. Accepted assignments, results, original execution
principals and root resource accounting are retained. Old worker read grants
stop matching the current owner, and stale-epoch control writes refuse.

A crash after external ownership acceptance leaves the local session frozen.
Retry reads the same intent and fence, obtains the same ownership receipt and
converges. Final acceptance records an already established fact even after root
cancellation; the cancelled root still refuses new work. It does not restore
write permission. Duplicate transfer requests return their original intent
without consulting a changed objective snapshot or selecting another successor.

IR-11 and IR-13 still own the real providers. Consumer adapters and deterministic
tests are deliberately separate from that production acceptance. Missing
providers refuse new handoff admission; they never default to a successful
fence or fabricate a receipt.

## Alternatives rejected

Transferring on lease expiry would permit simultaneous writers. Cancelling a
child would invent evidence about external effects. Replacing the session or
root would reset limits and abandon accepted work. Updating local ownership
before receiving the checkpoint acknowledgement would conceal a cross-owner
conflict. Retrying a new transfer after an unknown receipt would duplicate an
already accepted ownership change.

## Consequences

An unresolved handoff may intentionally remain frozen until its real owners
supply evidence. Provider proof IDs are correlation receipts, not bearer grants.
All adapters must enforce current action authority as well as deduplication.
Roll forward after writing the new session phase; older readers fail closed on
that phase. The new aggregate transitions change its generated fold fingerprint,
invalidating snapshots while retaining historical event replay. Existing
workflow labels, generation seeds and one-shot delegation shapes are unchanged.
Real restart/late-write repository tests remain a plan-84 completion gate.

## References

- [Plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md)
- [ADR 0061](0061-continuing-sessions-own-ordered-assignments-and-retained-receipts.md)
- [ADR 0062](0062-session-generations-await-governed-children-and-retain-checkpoint-intents.md)
- [IR-11](../improvement-requests/provide-governed-mutable-repository-workspaces.md)
- [IR-13](../improvement-requests/support-optional-major-task-tracking.md)
