---
id: 137
slug: settle-kioku-distillation-timers-through-kioku-s-fire-api-in-the-shared-timer-dispatcher
title: "Settle Kioku distillation timers through Kioku's fire API in the shared timer dispatcher"
kind: exec-plan
created_at: 2026-11-17T18:07:51Z
intention: "intention_01m7nb28daea1ak8jb6ga2ccxc"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-17T18:07:51Z
---

# Settle Kioku distillation timers through Kioku's fire API in the shared timer dispatcher

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Every agent run and every Danwa conversation records a Kioku session, and Kioku schedules
*distillation timers* for it: rows in Keiro's shared timer table that ask, later, for the
session to be distilled into memories. Kioku names three of them by process manager:
`kioku-l1-extract` (per-session extraction, payload `kind` `idle`, `ramp` or `final`),
`kioku-l2-scene` and `kioku-l3-persona` (whose payloads carry no `kind`). Shikigami's timer
loop is the only thing that claims due timers in a Shikigami deployment, and it does not
know these rows. Today each one is claimed, logged as an error and abandoned:

```text
{"event":"scheduler.timer.unknown_kind","level":"error","timer_id":"85ac4264-…","timer_kind":"final",…}
{"event":"scheduler.timer.unknown_kind","level":"error","timer_id":"9342344d-…","timer_kind":null,…}
```

An abandoned row stays `firing` until Keiro's stale requeue (300 seconds) puts it back,
then it is claimed and logged again, with its attempt count rising, for as long as the
worker runs. Nothing ever settles it, and nothing distills the session. The acceptance run of
`docs/plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md`
(M3) showed two such lines per finished run.

After this plan, the timer loop hands every Kioku-owned row to Kioku's own public fire and
outcome functions, as ADR-64 decided. Distillation stays switched off in this plan, as it is
today: Kioku then settles each row once, as a dead-lettered timer whose reason names the
disabled feature, and logs that. An operator sees no `scheduler.timer.unknown_kind` line for
a Kioku row, sees each distillation timer end in one visible terminal state, and the loop
stops spending claims on rows it can never fire. A row whose kind no owner claims is still
reported, as it is now. Running distillation for real, with its bounded model calls, remains
the work of plan 34 (see Context and Orientation), which this plan prepares for.


## Progress

- [ ] M1: The shared timer fallback routes `kioku-l1-extract`, `kioku-l2-scene` and
  `kioku-l3-persona` rows to Kioku's fire and outcome functions with distillation disabled,
  in both the worker's timer loop and the standalone scheduler. A workers test schedules one
  row of each kind and shows, after one timer pass, each row `dead` with a reason naming the
  disabled feature, exactly one claim each, no `scheduler.timer.unknown_kind` line, and an
  unknown non-Kioku row still reported.
- [ ] M2: A real run settles its distillation timers: after one declared agent run through
  `shikigami-worker`, the worker log has no `scheduler.timer.unknown_kind` line and every
  Kioku-owned timer row for the run's session is `dead` with Kioku's reason after its
  `fire_at`. The operations documentation and ADR-64's status say what happens to
  distillation timers while distillation is disabled.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Route Kioku's rows through Kioku's public functions (`fireKiokuTimer` and
  `applyFireOutcome` in `Kioku.Distill.Timer.Worker`) inside the existing fallback, not a
  second timer poller and not private SQL.
  Rationale: ADR-64 decided exactly this ("Kioku timers use the existing shared claimed-row
  dispatcher and Kioku's public fire/outcome APIs") and rejected a second generic poller,
  which would race the one Shikigami already runs.
  Date: 2026-11-17
- Decision: Build the `DistillRuntime` from `Kioku.AI.Runtime.disabledAIRuntime`, never from
  the runtime `Kioku.AI.File.loadAIRuntime` reads from `KIOKU_AI_CONFIG`. A Kioku row is
  therefore settled by Kioku's disabled-feature path and never makes a model call here.
  Rationale: `loadAIRuntime` can enable model features for recall embeddings, and using it
  would start live distillation in the timer pass without the bounds ADR-64 requires (one
  timer per pass when distillation is live, a 30-second callback budget, bounded source and
  candidate reads). Those bounds are plan 34's milestone M1; this plan stops the churn
  without starting model calls.
  Date: 2026-11-17
- Decision: This plan stands alone rather than as a milestone of plan 34.
  Rationale: Plan 34's M1 also needs upstream Kioku changes (bounded reads for live
  distillation) that this subset does not. The route this plan adds is the one plan 34 M1
  will keep; plan 34 then swaps the disabled runtime for a bounded live one and adds the
  per-pass limits.
  Date: 2026-11-17


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**Keiro timers.** Keiro (`mori://shinzui/keiro`) keeps one timer table that any process
manager can schedule into. A *timer row* (`Keiro.Timer.TimerRow`) has a `timerId`, a
`processManagerName` naming its owner, a `correlationId`, a `fireAt`, a JSON `payload`, an
`attempts` count and a status (`scheduled`, `firing`, `fired`, `dead`). A worker *claims* a
due row (status becomes `firing`, `attempts` goes up by one) and calls a *fire action*,
`TimerRow -> Eff es (Maybe EventId)`. If the action returns `Just eventId`, Keiro marks the row
`fired`. If it returns `Nothing`, Keiro leaves it `firing`; a later pass moves a `firing` row
whose last update is older than the stale-requeue age (300 seconds by default) back to
`scheduled`, and it is claimed again. `Keiro.Timer.deadLetterTimer` moves a row to `dead` with a
reason an operator can read. See `keiro/src/Keiro/Timer.hs` in the Keiro checkout
(`mori path mori://shinzui/keiro`).

**Shikigami's timer dispatch.** `Keiro.Workflow.Sleep.drainWorkflowSleepTimers` claims up to
100 due rows per pass, wakes workflow sleeps itself, and passes every other row to a fallback.
Shikigami's fallback is `shikigamiTimerFallback` in
`shikigami-workers/src/Shikigami/Trigger/Scheduler.hs`. It reads the payload's `kind` field and
routes the kinds Shikigami owns: scheduled agents (`scheduleTimerKind`), recurring mandates,
adaptive-delivery cutoffs, execution observations, approval timeouts and conversation idle
timeouts. Any other kind, or a payload with no `kind`, is logged as
`scheduler.timer.unknown_kind` and returns `Nothing`. Two places drain with this fallback:

- the worker's timer loop, `shikigami-workers/src/Shikigami/Trigger/Timer.hs`, line 38
  (`drainWorkflowSleepTimers metrics now 100 (Scheduler.shikigamiTimerFallback scheduler now)`);
- the standalone scheduler, `runSchedulerTimerWorker` in
  `shikigami-workers/src/Shikigami/Trigger/Scheduler.hs`, called by
  `shikigami-workers/src/Shikigami/Workers/Command/Scheduler.hs` and by the distribution's
  watchdog tests in `packs/kikan-shikigami/test/Kikan/`.

`SchedulerEnv` (same module) carries what the fallback needs; the worker builds it in
`shikigami-workers/src/Shikigami/Workers/Config.hs` and the scheduler in
`Workers/Command/Scheduler.hs`.

**Where the Kioku rows come from.** Kioku (`mori://shinzui/kioku`), the memory store, is
pinned at `kioku-core ==0.12.0.2` in `cabal.project`. Its session commands apply inline
projections that schedule distillation timers. `Kioku.Distill.Timer.l1TimerScheduleProjection`
schedules `kioku-l1-extract` rows with payload `L1TimerPayload {kind, turnCount,
memorySpaceId}`, `kind` being `idle` (30 minutes after the last turn), `ramp` (on turns 1, 2,
4, 8, 16 and every sixteenth) or `final` (when the session completes or fails); Shikigami
applies it itself for conversation turns at `shikigami-core/src/Shikigami/Agent/Conversation.hs`
line 1446. `Kioku.Distill.L2` and `Kioku.Distill.L3` schedule `kioku-l2-scene` and
`kioku-l3-persona` rows whose payloads have no `kind`, which is why one log line shows
`"timer_kind":null`.

**Kioku's fire API, in 0.12.0.2.** `Kioku.Distill.Timer.Worker` exports:

```haskell
fireKiokuTimer ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryContextProvider (Eff es) -> DistillRuntime -> FindMergeCandidates es -> TimerRow -> Eff es FireOutcome

applyFireOutcome :: (IOE :> es, Store :> es) => TimerRow -> FireOutcome -> Eff es (Maybe EventId)
```

`fireKiokuTimer` offers the row to the L1, L2 and L3 handlers; each recognizes its own rows by
`processManagerName` and returns `FireNotMine` for anything else. `FireOutcome`
(`Kioku.Distill.Timer.Outcome`) is `FireCompleted eventId`, `FireRetryLater delay note`,
`FireFailedPermanently reason`, `FireDeferred reason` or `FireNotMine`. `applyFireOutcome` turns
an outcome into timer state: `FireCompleted` returns the event id (Keiro marks `fired`); the
retry, failure and deferral branches reschedule or dead-letter the row themselves, log through
Kioku's timer logging, and return `Nothing`, so the row never sits in `firing`. When a
distillation feature is disabled, `Kioku.Distill.Runtime.distillAvailability` refuses with
`AIDisabled feature`, and `executionFireOutcome` maps that to `FireFailedPermanently`: the row is
dead-lettered once with a reason naming the feature and its memory space.

The other three arguments:

- `MemoryContextProvider` (`Kioku.Api.Access`, from `kioku-api`) answers, per memory space,
  whether the background pass may act there.
  `assumeAuthorizedContextProvider :: MemoryActor -> MemoryContextProvider m` is the
  embedded-host provider. Shikigami's sessions live in `shikigamiMemorySpace`
  (`shikigami-core/src/Shikigami/Memory/Access.hs`, equal to Kioku's `legacyMemorySpaceId`).
- `DistillRuntime` (`Kioku.Distill.Runtime`) is built with
  `newDistillRuntime :: AIRuntime -> Maybe FilePath -> DistillRuntime`;
  `Kioku.AI.Runtime.disabledAIRuntime` is the runtime with every feature off.
- `FindMergeCandidates` (`Kioku.Distill.L1`) is built with
  `recallCandidates :: AIRuntime -> VectorCapability -> Int -> FindMergeCandidates es`; L1
  consults it only after the availability check passes, so with distillation disabled it is
  never called.

Shikigami already runs Kioku effects with `runAppIO` (`Shikigami.App`), whose effect row
provides `Store`, `KirokuStoreResource` and `Error StoreError`, as `runKioku` in
`shikigami-core/src/Shikigami/Agent/Workflow.hs` does.

**Relevant ADRs.** [ADR-64](../adr/0064-memory-lifecycle-preserves-session-and-retention-ownership.md)
decides that Kioku timers go through the existing shared claimed-row dispatcher and Kioku's
public fire and outcome APIs; that with live distillation one timer is drained per pass and the
model callback is bounded to 30 seconds, while the disabled path keeps the 100-row ceiling; and
that no second generic timer poller is added. Its status says the implementation is pending in
plan 34. This plan implements the disabled path of that decision.

**Plan 34.** `docs/plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md`
(MasterPlan `docs/masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md`)
holds the full memory lifecycle. Its unfinished M1, "Drive Kioku timers through the shared
dispatcher", includes this route plus live distillation, which needs upstream Kioku bounded
reads first. This plan delivers the route with distillation disabled; plan 34 keeps the live
half.

**Existing tests to build on.** `shikigami-workers/test/Shikigami/SchedulerSpec.hs` has
"an unknown timer kind is reported, not silently approved" (around line 286), which asserts the
`scheduler.timer.unknown_kind` line for an unclaimed row; `TimerRecoverySpec.hs` and
`MandateTimerSpec.hs` in the same directory drive real timer passes against PostgreSQL.


## Plan of Work

### Milestone 1: route Kioku-owned rows to Kioku

Add one module, `shikigami-workers/src/Shikigami/Trigger/KiokuTimer.hs`, owning the route.
Sketch:

```haskell
-- | Kioku's distillation timers, settled through Kioku's own fire and outcome
-- functions (ADR-64). Distillation is disabled here: a row ends dead-lettered
-- with Kioku's reason, never firing a model (plan 137; live distillation is
-- plan 34).
module Shikigami.Trigger.KiokuTimer
  ( KiokuTimers,
    kiokuTimers,
    isKiokuTimer,
    fireKiokuRow,
  )
where

-- | What the fallback needs to settle a Kioku row: run Kioku's fire and
-- outcome functions in Kioku's effect row, against the store.
newtype KiokuTimers = KiokuTimers {settle :: TimerRow -> IO (Either StoreError (Maybe EventId))}

-- | Built once at start, from the application environment.
kiokuTimers :: AppEnv -> KiokuTimers

-- | The three process managers Kioku owns.
isKiokuTimer :: TimerRow -> Bool
```

`kiokuTimers` closes over `runAppIO appEnv`, `assumeAuthorizedContextProvider` for the actor
Shikigami records sessions as, `newDistillRuntime disabledAIRuntime Nothing` and
`recallCandidates disabledAIRuntime VectorExtensionUnavailable 1` (the vector capability is
irrelevant on the disabled path). Its `settle` runs `fireKiokuTimer` then `applyFireOutcome`.
A `FireNotMine` for a row `isKiokuTimer` accepted is a Kioku version mismatch: log it and return
`Nothing` so it surfaces as before.

Add `kiokuTimers :: !KiokuTimers` to `SchedulerEnv`, build it where the worker and the
standalone scheduler build their `SchedulerEnv`, and in `shikigamiTimerFallback` test
`isKiokuTimer row` before reading the `kind` field: a Kioku row goes to `settle`; a `Left`
store error is logged and returns `Nothing` (Keiro's requeue retries it). Log each settled row
once at info as `scheduler.timer.kioku` with `timer_id`, `process_manager` and the outcome
(`fired`, `dead`, `rescheduled`), so the route is visible without reading Kioku's own lines.
Leave `scheduler.timer.unknown_kind` for rows no owner claims.

Test it in `shikigami-workers/test/Shikigami/SchedulerSpec.hs`, beside the unknown-kind case,
against a migrated scratch database: schedule one due row per Kioku process manager with
Kioku's own payload shapes (an `L1TimerPayload` with kind `final`, an L2 scene payload, an L3
persona payload), plus one row of an unknown non-Kioku process manager; run one timer pass
(`runSchedulerTimerWorker`) and assert each Kioku row is `dead`, its reason names a disabled
feature, its `attempts` is 1, a second pass claims none of them, the log has one
`scheduler.timer.kioku` line per row and no `scheduler.timer.unknown_kind` line for them,
and the unknown row is still reported.

### Milestone 2: a real run, and the record

Run one declared agent through `shikigami-worker` on a disposable database (Concrete Steps)
and check the worker log and the timer rows. A finished run completes its Kioku session, so its
`final` row is due at once (the M3 acceptance of plan 135 saw it within seconds); its `idle` row
comes due 30 minutes after the last turn, so either keep the worker running past that or accept
on the rows already due and say so. Then update `docs/operations/` (the memory and timer operations page, or
`docs/user/memory.md` if that is where distillation is described) to say that, with
distillation disabled, each Kioku distillation timer is dead-lettered once with the disabled
feature named, how an operator sees it, and that plan 34 adds live distillation. Update
ADR-64's status line to say the disabled path is implemented by this plan and live distillation
remains with plan 34.


## Concrete Steps

From the repository root. The development shell exports `PG_CONNECTION_STRING` for the
development database, and the environment outranks `--config`; clear it for any disposable run.

```bash
cabal build shikigami-workers shikigami-workers:test:shikigami-workers-test
cd shikigami-workers && $(cabal list-bin shikigami-workers:test:shikigami-workers-test) -p '/Scheduler/' && cd ..
```

Expected after M1, among the Scheduler cases:

```text
    an unknown timer kind is reported, not silently approved:                 OK
    Kioku distillation timers settle through Kioku with distillation off:     OK
```

For M2, a disposable PostgreSQL on loopback TCP (a Unix socket under a long scratch path
exceeds the 104-character limit on macOS), migrated with `shikigami-migrate up`, then:

```bash
env -u PG_CONNECTION_STRING -u DATABASE_URL shikigami --config <config.json> enqueue-run <agent> --payload '{}'
env -u PG_CONNECTION_STRING -u DATABASE_URL shikigami-worker --config <config.json> > worker.log 2>&1 &
echo $! > worker.pid
grep -c scheduler.timer.unknown_kind worker.log      # expect 0
grep scheduler.timer.kioku worker.log                # one line per settled Kioku row
kill "$(cat worker.pid)"
```

Build every changed suite by name before running it (`cabal build all` does not build test
suites here, FRIC-98).


## Validation and Acceptance

M1 is accepted when the new Scheduler case passes and the existing unknown-kind case still
passes, with the assertions listed in Milestone 1: one claim per Kioku row, each row `dead`
with a reason naming the disabled feature, no unknown-kind line for a Kioku row, and an unknown
non-Kioku row still reported. The full workers suite, `just haskell-conventions` and
`just kernel-fitness` must pass.

M2 is accepted when one declared agent run through `shikigami-worker` leaves no
`scheduler.timer.unknown_kind` line in the worker log over at least two stale-requeue periods
(more than 600 seconds) after its timers come due, every Kioku row of the run's session that has come due is
`dead` with Kioku's reason, and the documentation and ADR-64 status say so.

Not part of this plan: running distillation (plan 34 M1), removing the timers Kioku schedules
while distillation is off, or changing Kioku.


## Idempotence and Recovery

The route is idempotent under Keiro's at-least-once contract: a row settled to `dead` is not
claimed again, and a row abandoned by a crash between claim and outcome is requeued and settled
on a later pass. Rows already stranded in an existing database (`firing` or `scheduled` with a
high attempt count) are claimed after their next stale requeue and settled the same way; no
migration is needed. Keiro exposes no public requeue for a `dead` row, so whether plan 34
requeues the rows this plan dead-letters, once distillation runs, is plan 34's decision; record
the count of such rows at M2 so it can make it. To undo, remove the `isKiokuTimer` branch;
rows return to the current unknown-kind behaviour.


## Interfaces and Dependencies

- `kioku-core ==0.12.0.2` (pinned in `cabal.project`): `Kioku.Distill.Timer.Worker`
  (`fireKiokuTimer`, `applyFireOutcome`), `Kioku.Distill.Timer.Outcome` (`FireOutcome`),
  `Kioku.Distill.Runtime` (`newDistillRuntime`, `DistillRuntime`), `Kioku.AI.Runtime`
  (`disabledAIRuntime`), `Kioku.Distill.L1` (`recallCandidates`, `FindMergeCandidates`),
  `Kioku.Distill.Timer` (`l1ExtractProcessManagerName`) and the L2 and L3 process manager
  names. All are exported by 0.12.0.2 (checked against its release commit, 5a62c3e, in the
  Kioku checkout).
- `kioku-api`: `Kioku.Api.Access` (`MemoryContextProvider`, `assumeAuthorizedContextProvider`).
- `keiro`: `Keiro.Timer` (`TimerRow`), `Keiro.Workflow.Sleep` (`drainWorkflowSleepTimers`).
- New in `shikigami-workers`: `Shikigami.Trigger.KiokuTimer` (`KiokuTimers`, `kiokuTimers`,
  `isKiokuTimer`), and a `kiokuTimers` field on `Shikigami.Trigger.Scheduler.SchedulerEnv`.
  If `tools/style/module-ownership.json` classifies workers modules, classify the new one under
  the `Trigger` concept.
