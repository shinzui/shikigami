# 0055. Execution drivers rotate around accepted work

Date: 2026-10-28

Status: accepted

## Context

An executor can finish after its submitting workflow process disappears. Queue
delivery can also exhaust retries without dispatching. Keeping the workflow lease
open during provider or tool work couples unrelated concurrency limits, while
replaying a journaled pending observation forever prevents progress.

## Decision

The new `shikigami.execution` workflow performs bounded decisions and submissions.
Each generation restores its execution identity, allocates a declared observation
wake, and records one advance action. It then finishes, waits, requests the existing
approval child, or rotates. Provider and tool callbacks run only through the queue
executor outside that workflow advance. The shared service registry owns this
family alongside agent runs, conversations and approvals.

Persisted execution/operation/attempt rows determine progress. A lost submission
response or queue delivery reuses the accepted job reference before considering
another actual attempt. Observation deadlines repair delivery through the existing
timer and queue owners. Redispatch still requires the conditional executor claim
and start; observation never grants that authority. Dispatched uncertainty retains
its cursor and reservation. A retained late receipt can be reconciled through an
identity-bound facts writer after replay access is revoked, without returning its
protected body or authorizing another effect.

The latest accepted model input is a bounded context checkpoint. Replay appends
its accepted response and subsequent tool observations in committed position order.
Earlier protected inputs and raw outcomes remain retained; compaction does not
erase history. Required tool observations that exceed the context ceiling refuse
explicitly. Ordinary metadata inspection never reads these payloads.

A permission wait holds the same accepted operation and approval child across
restart; the driver does not rotate while awaiting that child. The stored absolute
expiry wins over a late approval. Resolving the child records a decision only.
Fresh authority and root controls still gate submission and dispatch. Cancellation
can abandon an undispatched reservation and record a terminal failure without
claiming that an already dispatched uncertain effect stopped.

## Alternatives rejected

Holding workflow leases during callbacks would make workflow capacity an executor
pool. Treating a queue retry as a new actual attempt would double-spend allowance.
Replaying a frozen observation without rotation would never inspect the new
outcome. Reading the entire raw transcript on every turn would make memory use
grow with execution lifetime. Human approval cannot replace fresh authorization.

## Consequences

The driver is an independently tested callable workflow, with metadata-only
results and bounded journals. Existing agent and conversation bodies still need
their real patch branches before they adopt it; this decision does not claim that
production Skill recovery is complete. Policy configuration, recorded summaries,
class-specific recovery and full qualification remain in plan 83. Workspace and
objective providers remain separately owned.

## References

- [Plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md)
- [ADR 0030](0030-an-approval-request-is-a-durable-child-workflow.md)
- [ADR 0053](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md)
- [ADR 0054](0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md)
