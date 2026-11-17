# 0132. A stopped process instance releases its runtime permits

Date: 2026-11-17

Status: accepted. Amends [ADR-109](0109-runtime-capacity-admission-shares-accepted-attempt-fences.md).


## Context

[ADR-109](0109-runtime-capacity-admission-shares-accepted-attempt-fences.md) admits accepted
attempts through one database-wide capacity control. A dispatched attempt keeps its runtime
permit until a factual settlement, a pre-dispatch refusal, or its own executor's finalizer
releases it. Lease expiry never releases it, because the former executor might still be
running.

A process that dies never runs that finalizer. FRIC-99 shows what follows. The objective
continuity scenario kills the worker while an objective-creation tool is dispatched. Recovery
supersedes the attempt, which keeps its permit, and submits a replacement. The objective tool
records the superseded attempt's receipt, which would settle that permit, only when the
replacement runs. With the default capacity of one, the replacement is never admitted, so
every delivery defers and the observation timer re-enqueues it every minute, indefinitely.
Every other execution in the deployment waits behind the same slot. ADR-109 anticipated
recovery alongside unknown work only in tests that raise capacity, so the default
single-worker deployment could not recover from a crash during any dispatched tool.

The missing fact was not that an attempt's lease had expired but that its executor had
stopped. A clock cannot supply that fact. The database can.


## Decision

**A process claims under an enrolled instance.** On its first claim against a database, a
process inserts a row into `shikigami.execution_instances`. While any of its executors is in
flight, it holds a session advisory lock on that instance's number (lock class `1397246789`)
on a dedicated connection. It takes the lock when the first executor starts and releases it
when the last one finishes. `Shikigami.Execution.Instance.withExecutorInstance` owns this,
and the executor holds it from its claim to the end of its run. Each permit that admission
grants records the claimant's instance.

Releasing the lock between executors is safe. A finished executor has already released its
permit, so any permit still active under a free lock is either an undispatched claim, which
reclamation skips, or one whose finalizer failed, which should be reclaimed. Re-taking the same
number is safe too, because permits are stamped only after the lock is held.

**A free instance lock is a stop acknowledgement.** PostgreSQL releases a session's locks
only when that session ends: the process released the lock after its last executor, or the
process exited, was killed or lost its connection. Before admitting a claim, `claimExecutionAttemptAs` asks
`Capacity.stoppedTicketsTx` for active permits whose instance lock it can take. It holds that
lock until the end of its transaction. For each listed permit whose attempt has been
dispatched or has finished, it calls `Capacity.reclaimTx`, which settles the permit. This
releases only runtime occupancy. Unknown root usage stays charged, and the attempt's phase,
uncertainty and receipts are unchanged. An undispatched claim keeps its permit, because its
next claim already transfers that permit from the expired owner.

**A lost lock connection is replaced.** A watchdog pings the lock connection every five
seconds. If the connection stops answering, it is dropped, and the next executor re-takes the
lock on a fresh connection. Executors already running continue, bounded by their run
timeout. Their permits may be reclaimed meanwhile, so for at most that bound the
deployment can run more executors than its limit. Their outcomes stay correct: a late
completion or settlement of a reclaimed permit finds it settled.

**Claims without an instance behave as before.** A permit granted before migration 0053, or
by a claimant that enrolled no instance (an empty connection string, a failed enrollment, or
an in-process test claim through `claimExecutionAttempt`), records none and is released only
by settlement.


## Alternatives rejected

**Release a permit when recovery supersedes its attempt.** This is safe only for operations
declared repeatable or idempotent. A crash during any other tool would still pin the slot
indefinitely, and it would admit a replacement while the old executor might still be running in a
live replica.

**Raise the default capacity.** Every crash would still leak one slot permanently, so a
deployment would stall after as many crashes as its capacity.

**Treat claim expiry as a stop.** This is exactly what ADR-109 rejected: an expired lease
says nothing about whether the executor has stopped.

**Record the claim transaction's backend.** Pool connections are recycled while the process
lives, so a closed claim connection is not evidence that the process stopped.

**Exit the process when the lock connection fails.** Test fixtures drop their databases
`WITH (FORCE)`, which ends every session, including the lock connection. Crash-only exit
would end the test process. Replacing the connection keeps the guarantee for new work and
bounds the overlap by the run timeout.

**Hold the lock for the whole process lifetime.** This was the first implementation. It kept
one connection open for every database a process had ever executed against, so an idle
worker held a connection it did not need. Each test database that ran an executor also kept
one open until the database was dropped, in suites that already exceed the ephemeral
server's 100 connections at this machine's default 36-way test concurrency.


## Consequences

A worker killed during a dispatched tool no longer stalls the deployment. Its recovery is
admitted at capacity one, and the unmodified `tests/objective-tracking/run.sh` passes its
restart step and every later step. `Capacity.admitTx` takes the claimant's instance, and
the executor claims through `claimExecutionAttemptAs`.

While executors are in flight, a process holds one more database connection outside its
pool. `validateHeadroom` does not count it. Each burst of execution that starts from idle
opens that connection once.

`shikigami.execution_instances` gains one row per process and database. Nothing removes
them yet; each row is an integer and a timestamp.

`Shikigami.Execution.Instance` keeps a process-global registry keyed by connection string,
because the lock it guards stands for the process's own executors.


## References

- [ADR-109](0109-runtime-capacity-admission-shares-accepted-attempt-fences.md)
- [FRIC-99](../friction-log/99-the-objective-continuity-scenario-strands-its-run-after-the-injected-worker-kill.md)
- [Durable execution operations](../operations/durable-execution.md)
