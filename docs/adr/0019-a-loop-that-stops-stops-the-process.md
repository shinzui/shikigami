# 0019. A loop that stops stops the process

Date: 2026-08-20

Status: accepted


## Context

Each Shikigami worker-role executable runs one or more long-running loops: the
run-job queue processor, the Keiro workflow resume worker, the sink outbox
publisher, the Keiro timer worker, the scheduler's timer pass, and the two Kafka
consumers. Every one of them is infinite by design — there is no amount of work
that finishes them.

Three of them could stop while the process stayed up and looked fine.

`runWorkers` composed its four loops with nested `concurrently_`. That propagates
an exception from any branch, cancelling the others, which is right. But a branch
that *returns* is treated as one that finished successfully, and `concurrently_`
goes on waiting for the rest. For an infinite loop, returning is not success — it
is the loop having stopped without saying so.

Two loops actually returned. `runQueueWorker` ran its processor under Shibuya's
`IgnoreFailures` strategy, which by definition never restarts or propagates a
failed child; when the processor died, `waitApp` returned normally and the code
fell through to `pure ()`. `runResumeWorker` called its runner once and returned
on a `Left`. In both cases the process kept running its remaining loops with
nothing draining the queue, or nothing resuming workflows, and no signal to any
operator or supervisor.

Shibuya offers no processor-level restart. Its only two strategies are
`IgnoreFailures` and `StopAllOnFailure`, neither of which restarts a failed child,
and its retry story is per-message rather than per-loop. So the choice was between
building a supervisor inside the process and letting the process die so that the
external supervisor — process-compose's `restart: on_failure`, systemd's
`Restart=always` — starts a clean one.


## Decision

**A loop ending — by throwing or by returning — tears down its siblings and exits
the process non-zero. Bounded retry belongs inside a loop, for a dependency; it is
never a response to a loop.**

Concretely:

* Loops are composed by `Shikigami.Workers.Supervision.superviseLoops`, which
  converts a clean return into a `LoopExited LoopName` throw before letting it
  propagate. The exception naming the loop reaches `main`, so the process's dying
  words identify the failure.
* `runQueueWorker` treats a return from `waitApp` as a silent death: it logs
  Shibuya's metrics map and throws `LoopExited QueueLoop`.
* `runResumeWorker` restarts its runner with capped backoff — one second doubling
  to thirty — and exits after five consecutive short-lived runs. A run that lasted
  long enough resets the tally, because what distinguishes a broken worker from an
  unlucky one is not how many times it restarted but whether it stayed up in
  between.
* The probe listener is composed with the work by the same rule. A listener that
  cannot bind takes the process down rather than leaving it running invisibly, and
  work that dies takes the listener down rather than leaving a socket answering
  200 for a process that has stopped.
* Loops still swallow the errors they are supposed to swallow. A `StoreError` in
  the outbox, timer, or scheduler loop is logged and the pass retried, because the
  rows and timers are durable and the dependency will come back. Any other
  exception propagates.


## Alternatives rejected

**In-process per-loop restart supervision.** More code, and it duplicates what an
external supervisor already does better. A restarter has to decide which state the
dead loop corrupted, and the honest answer is usually "unknown". It also risks
masking a genuine fault as an infinite restart loop, which is the failure mode
that makes a half-working deployment look healthy for days.

**Keeping `IgnoreFailures` semantics at the process boundary.** That is what
produced the bug. Ignoring a failed child is the right policy for one poisoned
message and the wrong policy for a dead processor, and Shibuya's strategy cannot
tell those apart. Distinguishing them is the caller's job, which is what reading
`waitApp`'s return now does.

**Raising the backoff ceiling so the resume loop never exits.** A loop that
retries forever is indistinguishable, from outside, from a loop that is working.
Exiting hands a persistent fault to the layer that can page someone.


## Consequences

A worker process is now expected to exit on faults it previously survived. Any
deployment of these binaries needs a supervisor with a restart policy;
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`
owns supplying one. Running a worker bare in a terminal will show it exiting where
it used to sit there quietly.

This is observable, not theoretical: killing PostgreSQL under a running
`shikigami-worker` stops the Shibuya processor, and the process logs
`worker.queue.stopped`, throws `LoopExited QueueLoop`, cancels its three siblings,
and exits `1`.

The exit is deliberately louder than a tidy shutdown — an uncaught exception with
the loop's name — because a quiet non-zero exit is easy to mistake for a normal
stop in a log aggregator.

Adding a loop means adding it to a `superviseLoops` list and to `LoopName`; a loop
composed some other way is outside this rule and will reintroduce the bug.
`LoopName` is also what the liveness probe reports, so the two stay in step by
construction.

One coverage gap is deliberate. This rule catches a loop that *stops*, not one
that wedges inside a single iteration. Wedging is the liveness probe's job — see
`Shikigami.Health.Worker` — and the two mechanisms are complementary: fail-fast
needs no probe and no operator, while the probe catches what fail-fast cannot see.
