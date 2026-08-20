# 0016. A cron agent runs about now, not once per missed minute

Date: 2026-08-20

Status: accepted


## Context

The scheduler arms one durable keiro timer per scheduled agent, fires it when it
comes due, enqueues a run, and arms the next one. It re-armed from the tick that
had just fired. `nextDue` returns the first cron match strictly after its
argument, so feeding it a past instant yields another past instant.

Only one timer exists per agent at a time, so a backlog did not appear at once.
Instead each pass of the timer loop claimed the one stale timer, fired it, and
armed the next still-stale one. The loop sleeps a second between passes, so a day
of downtime on a `* * * * *` agent drained 1440 stale runs over roughly twenty-four
minutes — each with a distinct idempotency key `agent:sched:<minute>`, so nothing
deduplicated them, and each running an agent against data that had moved on hours
ago.

Keiro's timer layer has no catch-up policy of its own; a past-due timer is simply
claimed and fired late. The policy is this runtime's to choose.


## Decision

**A schedule declares a cadence, not a debt. After downtime, the scheduler arms
the first tick strictly after now.**

`Shikigami.Trigger.Schedule.CatchUpPolicy` has two constructors. `SkipMissed`,
the default, re-arms from the instant keiro claimed the timer at. `FireAll`
re-arms from the tick that fired, reproducing the previous behavior. The value is
resolved from the configuration key `scheduler.catch_up` (`skip_missed` /
`fire_all`) and reaches both the scheduler process and the worker's timer loop.

The instant is threaded in as a parameter rather than read again inside the fire
action, so a re-arm cannot disagree with the claim that produced it.

Waking a day late therefore produces exactly one run — the tick that was already
armed still fires — and then the normal cadence.


## Alternatives rejected

**A third `CoalesceToLatest` policy.** `nextDue` resolves to whole minutes and
the fire action enqueues the tick it was fired for before re-arming, so
"coalesce every missed tick into one" and "skip the missed ticks" produce the
identical observable result. Shipping two names for one behavior invites an
operator to believe there is a distinction to reason about.

**Deduplicating the backlog by idempotency key.** It would suppress the extra
runs after producing them, leaving the storm on the queue and the cost in the
worker. The producer is the right place to not create work nobody wants.

**Keeping `FireAll` as the default.** Replaying a day of stale minutes is almost
never what a cron agent's author meant, and the failure mode is a thundering herd
against downstream services at exactly the moment a deployment has just come back.


## Consequences

This changes behavior on upgrade, deliberately and in the direction that does
less. An operator who genuinely wants every missed minute sets
`scheduler.catch_up=fire_all`; no rollback is needed, and no state is left behind
that the old code cannot read.

Rolling back re-arms from the fired tick again and resumes the old behavior.

The observable acceptance is countable: stop the scheduler for several minutes on
a `* * * * *` agent, restart it, and `SELECT count(*) FROM pgmq.q_shikigami_run_jobs`
answers one rather than one per missed minute.
