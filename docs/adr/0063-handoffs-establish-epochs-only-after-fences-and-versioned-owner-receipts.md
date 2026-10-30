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

[Plan 96](../plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md) amendment (2026-10-29; implementation pending): the first real process owner uses
Linux systemd system services with cgroup v2, an independently supervised workspace service,
and an immutable filesystem root exposing only the admitted workspace and scratch writes.
Unsupported hosts refuse process admission. The supervisor retains operation/attempt,
workspace epoch, unit, invocation and boot identities, independently of queue-worker lifetime.
Transfer freeze and launch registration share a conditional per-workspace boundary. A fence
requires the entire descendant cgroup to be empty and a durable settlement receipt; main
process exit, a PID lookup or a missing unit is insufficient. Missing evidence after supervisor
or host failure remains unresolved. The selected backend must pass plan 96's real containment,
worker/supervisor restart and late-descendant tests before being enabled; this decision does
not assert that the provider has been implemented.

The Apple-container substrate probe now exercises a Nix closure in the immutable
root, effective unprivileged/PID/capability/syscall restrictions, and a detached
SIGTERM-ignoring writer that outlives an intermediate command parent. It proves
whole-cgroup stop and no later file writes. `PrivatePIDs` makes the service
process the namespace's PID 1, so a fixture that exits PID 1 cannot demonstrate
an independently surviving descendant. Preserve that profile and observe the
whole cgroup. These checks do not qualify an independent supervisor, output
collector, restart reconciliation or handoff receipt. See
[the root probe](../../tests/workspace/probe-root-apple.sh).

The workspace-side store (2026-10-30) retains transfer intents and fence proofs
separately from immutable allocation. Session and assignment coordinates come
from authoritative child mappings. A distinct successor admission binds the
actual new child to an already established session owner and its retained fence
and objective receipt. Only that conditional admission advances workspace
control; allocation and original effect receipts remain unchanged. Historical
writers must refuse the new filesystem profile before IO. The store contract is
implemented; concrete process fencing, transfer-aware adapters and native
successor writes remain plan-96 qualification gates.

The concrete workspace provider now treats its retained freeze as cancellation
control for the independent process owner. The shared lock serializes freeze
against file publication and process launch registration. Cancellation writes a
private marker and requests whole-unit stop; only matching collector evidence
and settled file/Git effects permit the retained fence. A restarted service may
recover an already admitted intent and return its factual proof after revocation,
without requesting a new launch or fabricating objective ownership. Version-2
peer-checked RPC carries this workspace-side contract; historical process frames
keep version 1. Instrumented process tests establish this boundary; real Linux
handoff and accepted successor writes remain plan-96 gates.

Transfer-aware file/process/Git adapters now check explicit retained successor
admission, current session ownership and the real actual claim at every effect
boundary. Their distinct profile and exact revisions prevent historical writers
from accepting successor coordinates. Fresh action targets explicitly bind the
successor run as well as assignment, owner and epoch; the original run was
previously implicit in immutable allocation. Successor loading preserves the
original ready Unix profile and pinned base instructions, then obtains fresh
exact authority before conditional control establishment. Cleanup follows the
latest retained successor execution, retaining live and idle sessions. The
accepted-read and instrumented process/Git tests pass; production selection
remains on the qualified older adapters until real Linux successor writes and
handoff pass.

## Alternatives rejected

Transferring on lease expiry would permit simultaneous writers. Cancelling a
child would invent evidence about external effects. Replacing the session or
root would reset limits and abandon accepted work. Updating local ownership
before receiving the checkpoint acknowledgement would conceal a cross-owner
conflict. Retrying a new transfer after an unknown receipt would duplicate an
already accepted ownership change.

Allocation reserves a stable workspace resource before filesystem IO and freezes its
repository, base, policy, source and provider storage root together with the assignment
coordinates. A retry cannot select another directory or reset accepted files. Private
Git metadata remains outside the mutable files exposed to validation. The concrete Git
allocator belongs in the workers package; core retains shared contracts and database
transactions. An allocation marker proves only publication of a complete private copy.
It grants no mutation authority and supplies no evidence that processes have settled or
that an old owner has been fenced. See [plan 96](../plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md).

Native file effects serialize with a private per-workspace OS lock, alongside
conditional owner/epoch and actual-attempt checks immediately before publication.
The lock is held through durable receipt acknowledgement and is released by
process death. Future freeze, transfer, Git and process launch owners must share
this boundary and reconcile unsettled reservations. File operations require all
supervised repository processes settled. Neither acquiring that file lock nor
reading an allocation/applied-edit marker proves descendant settlement; full
supervisor and transfer qualification remains pending in plan 96.

Terminal retirement (2026-10-30) uses a separate retained cleanup intent. Only
known terminal execution metadata, zero pending receipts, settled provider
effects/processes and absence of any live continuing session sharing the root
permit permanent admission freeze. Session idleness supplies no cleanup proof.
Fresh exact operator authority and the shared workspace lock guard deletion of
only the two recorded files/scratch root inodes. Recovery keeps that plan and
preserves provider metadata, receipts, source and Unix reservations. A missing
execution is not evidence that an orphan is safe to adopt. Retirement provides
no ownership-transfer proof; the real handoff/integration gates remain open.

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

Same-owner follow-ups at the original session epoch retain separate admissions
without manufacturing an ownership receipt or incrementing the epoch. They
require the prior assignment results and actual executions to be terminal and
all receipts settled. The original allocation, Unix profile and instruction
bundle remain pinned; cleanup follows the latest retained admission.

The native workspace-side gate now proves an in-flight detached writer and held
collector keep a transfer unresolved, then recovers the original actual and
exact fence across supervisor restart with authority denied. A real accepted
late old-owner file edit refuses after fresh authority returns. These facts do
not establish a successor epoch: no foreign ownership receipt is manufactured.
Accepted native successor writes and joint objective integration remain open.

The complete 22-case workspace-owned native matrix also verifies same-owner
follow-up writes and terminal cleanup bound to the latest retained execution,
while preserving the pinned instruction bundle, Unix identity and metadata.
This does not waive the separate real ownership/successor gate or activate the
new production composition.
