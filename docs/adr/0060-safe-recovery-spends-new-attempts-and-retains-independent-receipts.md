# 0060. Safe recovery spends new attempts and retains independent receipts

Date: 2026-10-28

Status: accepted

## Context

A dispatched attempt whose owner disappears remains unknown. Some trusted
operation classes permit another actual attempt, but that attempt cannot erase
the earlier transport's accounting or discard a later real receipt. In
particular, a late former reply must not replace the chosen replacement result.

## Decision

Recovery may repeat a trusted observation or an idempotent effect under the same
accepted logical operation, input, binding and trusted idempotency key. It
allocates a new actual attempt and reservation. A new bounded policy field,
`recoveryAttempts`, defaults to two for fresh policy values, supports 0–100, and
can only be narrowed by agent overrides. Historical absent fields decode to
zero and remain omitted on encoding. Uncertain effects never redispatch merely
because a claim expires.

One checked transaction retires the unknown attempt as superseded, reserves and
enqueues its replacement, and reopens logical progress. It retains the earlier
unknown reservation and increments a pending-receipt count. Capacity, profile,
permission, policy and fresh authority checks still apply. A refusal rolls back
the entire change and leaves the original unresolved state. Tool recovery
restores the exact response/position cursor from its immutable input; it cannot
skip the tool by interpreting uncertainty as a new model turn.

Superseded queue deliveries are observations and never signal a replacement's
awakeable with an old reference. A real former-owner receipt proves only that
actual attempt's accounting. Its acceptance and settlement share a transaction,
retain protected receipt data and decrement the pending count, without changing
the chosen operation outcome, logical cursor, next work or terminal result.
Identical repeats converge; conflicting receipts refuse. These factual writes
do not grant replay reads or new external authority.

The execution lifecycle keeps its historical terminal states and transitions.
New internal pending-receipt states allow a logically succeeded, failed or
cancelled execution to settle older actual attempts after its child finishes.
Final receipt closure has a distinct event so replay attributes each transition
unambiguously. Closing the last receipt reaches the original terminal state.
The public execution phase stays terminal throughout. Partial billing can remain
unknown in the resource owner even after transport completion is established.

[Plan 96](../plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md)
implements this contract for contained whole-file edits. A private prepared
receipt is fsynced before atomic file publication; applied/refused receipts and
conditional PostgreSQL reservations retain the same logical fingerprint. A
replacement attempt reconciles an applied receipt without rewriting the file.
The retained original actual attempt and claim generation supply its independent
late receipt to the existing execution owner. This settles only original
accounting; the replacement executor retains logical completion. A held OS lock
or missing/conflicting evidence remains unresolved, never a successful no-op.
Receipt files carry hashes and coordinates; accepted content remains in protected
execution payloads. Production worker admission and supervised process effects
remain separate plan gates.

A prepared edit receipt is intent rather than proof of publication by its actual
attempt. A replacement may reconcile the desired published content and settle
that original attempt. If publication is unproven, it must not perform the edit
and label the new work as the original attempt's completion. The current adapter
leaves that case unresolved with its original reservation and pending receipt.
The accepted-executor regression interrupts after prepared intent and proves no
replacement file write or fabricated former-owner receipt.

Process registration similarly retains the original attempt, deadline, unit and
boot/invocation identities. Duplicate launch requests never receive a second
launch transition. A pre-launch refusal is factual only while no transition
committed; it carries no invented process receipt. Metadata settlement does not
grant lifecycle or external action authority. The actual supervisor must supply
real invocation, bounded complete output and descendant evidence before its
receipt adapter can be enabled.

The independent output collector drains excess bytes while retaining a bounded
shared prefix in provider-private files. It holds a systemd unit reference on its
own D-Bus connection through receipt publication, so cancellation cannot discard
the invocation evidence before it is checked. A completion requires matching
boot, invocation and fingerprint, fsynced output and an empty descendant cgroup.
Collector loss leaves an unresolved registration; restarting capture cannot
claim output completeness. Factual reconciliation can retain the original
receipt after revocation, without granting new execution or output-read access.
The Apple-container collector probe qualifies this boundary; complete supervisor
launch, restart and execution-accounting integration remain plan-96 gates.

A settled timeout or cancellation can lack a numeric main wait status in the
qualified backend. Retain that absence explicitly, rather than manufacturing a
signal code. Exact invocation, complete bounded output and empty-cgroup evidence
can establish process settlement in that case; successful validation requires
an explicit normal completion and confirmed zero exit code. A normal completion
with no numeric status remains unresolved. Version-2 collector facts express
this distinction, while version-1 facts still require their numeric status.
Receipt readers reject an exposed metadata directory without repairing its
permissions and then trusting potentially modified evidence.

A process-supervisor transport/admission error carries no no-launch proof.
Only the retained pre-launch refusal, which competes with the single launch
transition, establishes that fact. A failure after the transition remains
uncertain even if a later guard refuses. Workspace receipt settlement alone
does not acknowledge the original execution attempt or release its accounting
hold; that owner must accept its actual late receipt. Independent recovery must
retain the minimal accepted completion routing before launch so revocation does
not require a new protected model-response read merely to record those facts.

The process owner now retains versioned completion routing before launch and
uses the execution owner's factual tool-receipt API, late reconciliation and
existing wake publication. A live claim stays with its executor; an expired or
already uncertain claim can settle from the original retained receipt without
allocating another actual attempt. The publisher validates original actor,
claim generation, accepted input and fingerprint, and grants no replay-read or
fresh execution authority. Root cancellation does not erase facts or unrelated
billing holds. Historical records without routing remain readable and gain no
launch authority. The independent service and real Linux restart fixture now
qualify this process boundary; production worker installation remains separately
gated by plan 96.

Supervisor intake uses a private filesystem Unix socket retained by systemd
socket activation. The service adopts only the configured listening stream
descriptor, authenticates kernel peer credentials before parsing a request,
and accepts retained execution/operation/actual-claim coordinates rather than
commands or host paths. The client verifies the server's Unix identity before
disclosing those coordinates. Fixed worker counts, message limits and request
deadlines bound intake. Restart closes only the service's descriptor copy;
it must not shut down or unlink the manager's listener. A transport error or
caller timeout keeps the original effect uncertain. Observation can recover
retained facts, but never issues a second launch. The live client and factual
publisher share deterministic result rendering. The native listener substrate
and accepted-executor Unix fixtures remain separate evidence boundaries. The
coupled Linux prototype additionally proves worker and supervisor SIGKILL,
retention of the manager-owned listener and original-attempt settlement.

Process profile revision 2 also binds an immutable deadline executable. It runs
as the unprivileged init of the private PID namespace, refuses expired starts
before executing repository code, retains orphan descendants and stops them at
the accepted absolute cutoff. A suspend-aware nonsettable timer bounds duration;
a discontinuous realtime change expires the guard. Repository code cannot trace
or write its trusted parent's memory, and cannot stop namespace init. Normal
success requires the command's confirmed zero and no remaining descendants.
Guard cutoff/refusal returns a nonzero unit status; it does not invent a
successful command result or claim a systemd timeout that was not observed.
The collector still independently checks matching invocation, bounded complete
output and an empty cgroup. Loaded units can wait in a queue before receiving
their first invocation identity: capture remains open for a bounded interval,
but an identity lost or changed after pinning remains evidence loss. Native
deadline and Nix-root probes qualify this substrate; the coupled accepted
fixture separately qualifies service restart integration. Apple VM agents can
periodically step realtime: such a change must still expire the guard. Short
qualification commands may coordinate with an observed clock step and release
a held payload after the intended restart boundary; this supplies no exemption
for a long-running command or proof of successful validation after clock loss.

The independent service also observes retained root cancellation, overage and
cutoff controls without reviving the former actor's authority. Under the shared
workspace lock it durably marks cancellation, verifies boot/unit/fingerprint and
any pinned invocation, and requests whole-unit stop while retaining the unit
object. Stop acceptance is never settlement: only the collector's matching
receipt with complete output and an empty descendant cgroup opens the process
barrier. Failed stops remain unresolved and retry only cancellation, never
launch. Missing current root data cannot fabricate a control decision or block
recovery of already retained completion facts.

Supervised workspace policies retain the complete reviewed rule set, immutable
image/helper coordinates, compiled containment-property identity and file
restrictions. Their content identity supplies the immutable workspace policy
revision. A separate durable profile reserves a unique unprivileged Unix id
from the operator's bounded pool, binds the workspace and instruction digests,
and records readiness only after trusted provisioning. Lost acknowledgement
returns the same identity and policy; expiry or freeze cannot recycle it.
The supervisor resolves ready retained rules, rather than current defaults,
and refuses incompatible compiled containment properties. Trusted launch
helpers cannot reside on writable workspace/scratch mounts; host images and
collectors cannot come from workspace storage. These metadata contracts do
not establish native Unix provisioning, effective containment or fencing.

Native provisioning has a separate fresh C13 target for the pre-model
assignment, reserved Unix identity, retained policy, host boot and anchored
workspace/scratch roots; it does not fabricate an execution attempt. Its
directory primitive requires provider serialization and no active repository
process, validates the entire tree before changing ownership, pins each inode
without following symlinks, and refuses special files and hard links. The first
process filesystem profile provisions at most 100,000 regular files/directories
with nesting at most 128; unsupported trees refuse. Interrupted changes can
recover only under the same reserved identity. Private metadata stays outside
the provisioned tree. A separate owned-publication primitive creates/replaces
files as that identity and preserves executable intent, so later isolated
commands retain access. Existing file-only publication keeps its original
behavior. The coupled provisioner retains prepared and ready private receipts,
refuses adoption without its own prepared receipt and checks the exact account,
group and supplementary groups before readiness. File adapter revision 2 binds
the complete ready profile into authority/recovery hashes, enforces retained
path restrictions and the process barrier, and uses owned publication. Revision
1 preserves its original hashes and refuses the supervised filesystem profile.
The configured socket-activated daemon uses existing directory/profile/C13
services and ready retained rules. These implementations and their separate
native/instrumented checks do not enable process-backed configured workers.
The ten-case coupled Linux prototype now qualifies native provisioning and
owned edits, duplicate requests, worker/supervisor restart, cancellation, offline
receipt recovery, isolation, missing-evidence retention and fresh denial. Local
Git receipt qualification and production composition remain plan-96 gates.

Local Git commit intent retains the original actual claim and an exact
parent/tree/result/changed-path plan before publishing HEAD. Immutable blob/tree
construction reads admitted bytes without invoking worktree filters or helpers;
commit construction disables hooks and signing, and publication checks the
expected parent. A single retained publication transition cannot be reissued
after acknowledgement loss. A prepared candidate establishes intent, while
only verified publication can establish completion. File and Git operations
share the same unsettled-effect barrier, with typed receipt kinds preserving
historical file encodings. Factual Git settlement after an owner freeze retains
the original claim; only the existing execution owner may acknowledge its actual
attempt and release accounting. These registration/object primitives remain
uninstalled until the accepted Git adapter, independent publisher and coupled
recovery fixture qualify that boundary.

## Alternatives rejected

Releasing the unknown attempt to make room for its replacement would invent
unused capacity. Reusing its actual attempt identity would hide transport cost.
Reopening the old terminal states would weaken their historical contract.
Overwriting the operation with a late response would replace accepted progress.
An independent retry queue would duplicate the existing fenced executor owner.

## Consequences

Finite active capacity can intentionally prevent recovery while an unknown call
still holds its slot. The operation remains visible and awaits evidence.
Accepted model turns and physical transport attempts have separate counts.
Generated fold fingerprints invalidate aggregate snapshots after this additive
extension; historical event replay and all behavior cells must pass the gate.
Real mutable workspace fencing remains owned by IR-11. This contract supplies
the harness seam and does not claim that a generic native tool is idempotent.

## References

- [Plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md)
- [ADR 0051](0051-resource-roots-own-conservative-reservations-and-actual-attempts.md)
- [ADR 0054](0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md)
- [ADR 0059](0059-harness-policy-is-frozen-at-admission-and-shared-with-ephemeral-execution.md)
