# 0109. Runtime capacity admission shares accepted attempt fences

Date: 2026-11-03

Status: accepted

## Context

Root reservations bound one objective across processes. They do not bound the
number of external operations that several runtime replicas execute together.
A per-process semaphore would multiply the effective limit with the replica
count. Reclaiming a dispatched permit merely because its lease expired could
admit new work while the former executor's outcome remains unknown.

## Decision

One database-wide capacity control admits accepted attempt tickets. Submission
retains a ticket under the attempt's existing identity and root. Claim admission
checks the authoritative root, current execution and attempt fence, global
occupancy and the next eligible ticket in the same short transaction. It grants
no new operation or provider attempt. Expired undispatched claims may transfer
only their existing permit, conditionally on the exact previous owner and the
existing attempt generation. Dispatched and uncertain work cannot use that path.

Admission serves the least recently admitted ready root, then its oldest waiting
attempt. Successful admission advances only that root's turn. This bounds rounds
between roots without creating a second root budget. Long external execution
holds no capacity transaction or workflow lease. Factual terminal settlement or
pre-dispatch refusal releases its exact permit with the existing outcome/accounting
transaction. A trusted local executor finalizer may also release its exact permit after the
local dispatch has returned or unwound; it does not settle unknown root usage.
Unknown dispatch without that stop acknowledgement retains occupancy until
reconciliation. Lease expiry alone is never a stop acknowledgement; raising
runtime capacity does not release root holds.

Capacity pressure defers an accepted queue delivery without spending its provider
retry allowance. The durable execution driver retains the operation, wait and
bounded timer repair, and republishes the same accepted reference. Foreground
execution reports pending. No replacement worker or operation is minted.

Execution capacity and workflow advance bounds have separate positive checked
configuration, both defaulting to one. The central workflow options owner applies
the advance bound; queue concurrency follows the configured execution bound.
Startup reserves four database pool connections beyond the sum of those bounds.
Initial capacity configuration can bootstrap once. Later changes require an
observed control revision; an older replica cannot silently restore a higher
limit after another operator lowers it. Lowering below occupancy drains existing
owners and blocks new admission until occupancy falls below the new limit.

## Alternatives rejected

Independent process semaphores do not enforce a deployment-wide limit. A second
queue or copied root counter would split accepted-work or budget ownership.
Expiring dispatched tickets would turn uncertainty into free capacity. Treating
ordinary capacity pressure as a failed queue retry would dead-letter valid work
without any failed provider attempt.

## Consequences

The additive migration conservatively enrolls retained waiting, claimed and
uncertain attempt references. Existing terminal codecs and workflow bodies retain
their meaning. All live executors must use this admission boundary; an older
executor binary predating it cannot enforce the new deployment-wide guarantee.
Accepted decision execution added by plan 85 must share these tickets and retain
plan 75 as its model-call evidence owner. Its typed submit/observe adapter and
held-decision qualification remain separate, unfinished acceptance gates.

## References

- [Plan 85](../plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md)
- [ADR 0054](0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md)
- [ADR 0060](0060-safe-recovery-spends-new-attempts-and-retains-independent-receipts.md)
- [ADR 0004](0004-one-options-value-and-a-checked-patch-set.md)
