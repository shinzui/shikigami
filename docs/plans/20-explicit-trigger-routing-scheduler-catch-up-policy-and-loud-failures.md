---
id: 20
slug: explicit-trigger-routing-scheduler-catch-up-policy-and-loud-failures
title: "Explicit trigger routing, scheduler catch-up policy, and loud failures"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tykwvek587vr2gwtcf81j"
master_plan: "docs/masterplans/3-correctness-and-delivery-semantics-stop-dropping-and-duplicating-work.md"
---

# Explicit trigger routing, scheduler catch-up policy, and loud failures

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Three classes of silent misbehavior make shikigami hard to trust. Routing is guessed, not declared: the worker decides whether a job is a conversation turn by trying to JSON-decode its payload as an addressed message, ignoring the `triggerKind` field the job already carries — so a schedule or stream job whose payload happens to look addressed is misrouted. The scheduler has no catch-up policy: after downtime it replays every missed cron minute in sequence, so a day of downtime on a `* * * * *` agent enqueues 1440 stale runs. And a family of errors is swallowed whole: kioku session/memory writes whose results are discarded with `_ <-`/`void`, agent manifests that fail to load and are dropped with no log, and crons that fail to parse and silently stop that agent's schedule forever.

After this plan, the worker routes on `RunJob.triggerKind` explicitly; the scheduler applies a configurable catch-up policy (default: skip missed ticks, arming only the next future one) so downtime cannot produce a run storm; kioku write failures are logged and counted instead of vanishing; and agent/cron load failures are loud per-file with a `--strict` mode that refuses to start when anything failed to load. You can see it working in the new test module `Shikigami.RoutingAndLoadingSpec` and the extended `Shikigami.SchedulerSpec`: a misaddressed schedule job routes correctly, a scheduler that wakes a day late arms exactly one future run, and loading the checked-in `agents/broken.dhall` reports the failure instead of silently dropping it.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: `routeRunJob` on `RunJob.triggerKind`; conversation payload decode failure becomes a typed dead-letter; tests.
- [ ] Milestone 2: `CatchUpPolicy` in the scheduler; `armNextRun`/`scheduleFireAction` coalesce missed ticks; `scheduleFireAction` no longer falls through to the approval fallback on non-schedule payloads; tests.
- [ ] Milestone 3: kioku result propagation/logging at the five discard sites (`Workflow.hs` open/record/complete/fail; `Agent/Run.hs`); counters or logs; tests where observable.
- [ ] Milestone 4: `loadAgentsLoud` with per-file logging, count, and strict mode across the three CLI loaders; unparseable-cron loudness in `Worker.hs` schedule extraction.
- [ ] Milestone 4 (hardening): enqueue-path fixes — idempotent addressed key, drop per-enqueue `createQueue`, epoch fallback, UUIDv5 non-ASCII bytes, partial `error` in `runQueueName`.
- [ ] Register new/extended specs in `shikigami-core.cabal` and `shikigami-core/test/Main.hs`; `cabal build all` and `cabal test all` green under `nix develop`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Route on `RunJob.triggerKind` (an explicit enum already on the wire) rather than on payload shape.
  Rationale: `triggerKind` is set by every producer (`Shikigami.Trigger.Enqueue`) and is exactly the routing signal; duck-typing on `AddressedMessage` decode is both wrong (false positives) and fragile. `TriggeredByEvent` carrying an addressed-message payload is the conversation path; the other kinds are the ordinary agent-run path.
  Date: 2026-07-08

- Decision: Default scheduler catch-up policy is skip-missed (arm only the next future tick); make it configurable via `CatchUpPolicy` with a coalesce-to-latest alternative.
  Rationale: A cron agent's value is "run about now", not "run once for every minute I was offline". Verified storm: `scheduleFireAction` re-arms from the fired `dueAt` (`Scheduler.hs:101-102` → `armNextRun cron agent dueAt`), and `nextDue` steps one interval, so a backlog drains one stale run per worker pass with distinct idempotency keys `agent:sched:<minute>` (`Enqueue.hs:101`). Skip-missed advances `nextDue` past `now` before arming.
  Date: 2026-07-08

- Decision: Only stop the silence around agent/cron load failures here (per-file log, count, `--strict` refusal to start); do not persist per-agent load state.
  Rationale: Durable per-agent load/lifecycle state belongs to docs/plans/23-agent-lifecycle-control-with-meibo-principals.md (MasterPlan 4), which introduces the meibo principal model. Building a throwaway store here would create migration debt. This is a declared MasterPlan integration boundary.
  Date: 2026-07-08

- Decision: Fix `scheduleFireAction`'s fall-through into the approval-timeout fallback for non-schedule timer payloads by giving the timer worker an explicit dispatch on timer kind, not by relying on `parseSchedulePayload` returning `Nothing`.
  Rationale: `shikigamiTimerFallback` (`Scheduler.hs:105-109`) tries the schedule action and, on `Nothing`, falls through to `approvalTimeoutFireAction`. A schedule timer whose enqueue fails also returns `Nothing` (`Scheduler.hs:99`), so a failed schedule fire is misinterpreted as an approval timeout. Dispatching on the timer payload's kind removes the ambiguity.
  Date: 2026-07-08

- Decision: Bundle the small enqueue-path hardening (idempotent addressed key, no per-enqueue `createQueue`, non-epoch occurredAt, UTF-8-correct UUIDv5 bytes, total `runQueueName`) into this plan's Milestone 4 rather than a separate plan.
  Rationale: They are one-to-few-line correctness fixes in the same trigger/enqueue surface this plan already owns, too thin to be their own ExecPlan. `createQueue` removal coordinates with docs/plans/18's `ensureRunQueue` (MasterPlan integration point on `Shikigami/Trigger/Enqueue.hs`).
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The worker drains the `shikigami_run_jobs` pgmq queue and, per job, dispatches to one of two orchestration paths. `handleRunJob` (`shikigami-core/src/Shikigami/Worker.hs:132-141`) decodes the `RunJob`, then chooses the path by attempting `Aeson.fromJSON (triggerPayload job)` as an `AddressedMessage`: on success it runs `runConversationAgent` (the danwa conversation loop), on failure `runOneAgent` (the ordinary agent-run workflow). `RunJob` (`shikigami-api/src/Shikigami/Api/RunJob.hs:19-30`) carries `triggerKind :: TriggerKind` where `TriggerKind = TriggeredBySchedule | TriggeredByStream | TriggeredByEvent | TriggeredByDelegation`. The duck-typed decode ignores this field entirely: a schedule or stream job whose payload coincidentally decodes as an `AddressedMessage` is misrouted into the conversation path; conversely a genuinely-addressed payload that fails to decode (a producer bug) silently falls through to the ordinary path instead of surfacing.

The scheduler is a keiro durable-timer loop. `armNextRun` (`shikigami-core/src/Shikigami/Trigger/Scheduler.hs:79-90`) computes `nextDue cron now` and schedules a one-shot timer (`scheduleTimerOnceTx`) at that due time. When the timer fires, `scheduleFireAction` (Scheduler.hs:92-103) parses the schedule payload, enqueues a `TriggeredBySchedule` run via `enqueueScheduledRun` (`shikigami-core/src/Shikigami/Trigger/Enqueue.hs:87-105`), and re-arms from the just-fired `dueAt` (Scheduler.hs:101-102). Because `nextDue` advances exactly one interval (`Trigger/Schedule.hs`), a scheduler that was offline for a day wakes, fires the oldest missed tick, arms the next (still in the past), fires it, and so on — draining 1440 stale runs for a `* * * * *` agent, each with a distinct idempotency key `agent:sched:<iso8601 minute>` (Enqueue.hs:101) so the worker's dedupe does not collapse them. keiro's timer layer has no catch-up policy of its own (verified: a past-due timer is simply claimed and fired late, keiro `src/Keiro/Timer.hs`). `shikigamiTimerFallback` (Scheduler.hs:105-109) composes the schedule action with `approvalTimeoutFireAction` and, because both a non-schedule payload and a failed-enqueue schedule return `Nothing` (Scheduler.hs:95, 99), a failed schedule fire is misread as an approval-timeout fire.

Swallowed kioku errors: kioku session/memory calls return `Either StoreError _`, but the results are discarded at `Workflow.hs:261` (`Session.start`, via `_ <-`), `Workflow.hs:377` (`Session.failSession`, `void`), `Workflow.hs:589` (`Memory.record`, `_ <-`), `Workflow.hs:610` (`Session.complete`, `void`), and in the non-workflow path `Agent/Run.hs:63,97,115` (`Session.start`, `Memory.record`, `Session.complete`). A store failure there means a run reports success with no session opened or no memory persisted, and no one is told.

Silent config loss: all three CLI loaders share the same `loadAgents` that drops failures — `[a | Right a <- loaded]` in `shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs:45-49`, `.../Scheduler.hs:77-81`, and `.../ConsumeStream.hs:90-94`. `loadAgent :: FilePath -> IO (Either LoadError AgentDecl)` (`shikigami-core/src/Shikigami/Agent/Loader.hs:21`) does return the error; it is thrown away. The checked-in `agents/broken.dhall` (a manifest with a `behaviour`/`behavior` typo) demonstrates the drop: it vanishes with no log. Separately, the worker's schedule extraction `scheduleFor` (Worker.hs:215-219) drops agents whose cron fails `parseCron` with `Left _ -> Nothing`, silently — an agent with a bad cron loads fine but never schedules, and after the first (manually enqueued) fire never fires again.

Minor verified hardening targets in this surface: `enqueueAddressedRun` embeds `now` in its idempotency key (`Enqueue.hs:64-67`) so it is not idempotent (the `WithKey` variant at Enqueue.hs:70-84 is the correct one); `enqueueRunJob` calls `createQueue` on every send (Enqueue.hs:55); `runJobFromEnvelope` falls back to the Unix epoch on an unparseable `occurredAt` (Enqueue.hs:39,48), silently backdating runs; `deterministicOutboxIdForMessage`/`scheduleTimerId`/`scheduleFiredEventId` build UUIDv5 name bytes with `fromEnum`-per-`Char` (Workflow.hs:555-559, Scheduler.hs:66-69,74-77), truncating non-ASCII agent names to the low byte and risking id collisions; and `runQueueName` uses a partial `error` on an invalid literal (Enqueue.hs:29-31).

Test infrastructure: `Shikigami.SchedulerSpec` (`shikigami-core/test/Shikigami/SchedulerSpec.hs`) already exercises the scheduler against a real Postgres via `withShikigamiMigratedDatabase`; extend it. Routing is a pure decision over `RunJob`, testable without a database. `agents/broken.dhall` is a ready-made fixture for the loader tests.


## Plan of Work

Milestone 1 — explicit routing. Scope: `shikigami-core/src/Shikigami/Worker.hs`. At the end, the path is chosen by `triggerKind`, and an undecodable conversation payload is dead-lettered rather than silently misrouted.

Add a pure decision:

```haskell
data RunRoute = ConversationRoute !AddressedMessage | AgentRunRoute | RouteError !Text

routeRunJob :: RunJob -> RunRoute
routeRunJob job = case triggerKind job of
  TriggeredByEvent ->
    case Aeson.fromJSON (triggerPayload job) of
      Aeson.Success addressed -> ConversationRoute addressed
      Aeson.Error _ -> AgentRunRoute        -- an event that is not an addressed message is an ordinary run
  _ -> AgentRunRoute
```

Rework `handleRunJob` (Worker.hs:132-141) to `case routeRunJob job of` → `ConversationRoute a -> runConversationAgent env job a`; `AgentRunRoute -> runOneAgent env job`; `RouteError e -> pure (AckDeadLetter (InvalidPayload e))`. Refinement to remove the remaining ambiguity: conversation agents are declared with the addressed-message event type (`addressedMessageEventType`), so an event job whose declared agent is a conversation agent but whose payload does not decode is a real error, not an ordinary run — if docs/plans/17 has landed, express that as `RouteError` routed through its `classifyOutcome`/ack taxonomy; if not, `AckDeadLetter (InvalidPayload …)` directly. This is the declared integration point with docs/plans/17 on `Shikigami/Worker.hs` (17 owns the ack taxonomy; 20 consumes it) — whichever lands second reconciles the handler.

Milestone 2 — scheduler catch-up policy. Scope: `shikigami-core/src/Shikigami/Trigger/Scheduler.hs`. At the end, waking late arms exactly one future tick, and a failed schedule fire is not misread as an approval timeout.

Add `data CatchUpPolicy = SkipMissed | CoalesceToLatest | FireAll` and a field on `SchedulerEnv` (default `SkipMissed`). Change `armNextRun` (Scheduler.hs:79-90) to advance to the first strictly-future due time under `SkipMissed`/`CoalesceToLatest`: iterate `nextDue` from `now` until the result is `> now` (bounded loop; `nextDue` is strictly increasing), and arm that. Under `FireAll`, keep today's behavior. In `scheduleFireAction` (Scheduler.hs:92-103), re-arm using the policy: `SkipMissed` arms the next future tick from `now` (not from the fired `dueAt`), so a backlog collapses to a single future run; `CoalesceToLatest` fires the current tick once and arms the next future one (same result at minute granularity, but explicit). Fix the fallback ambiguity: replace `shikigamiTimerFallback` (Scheduler.hs:105-109) with an explicit dispatch on the timer payload's `kind` — if it parses as a schedule payload, run the schedule action and treat its `Nothing` (enqueue failure) as a genuine failure to retry (return `Nothing` so keiro leaves the timer `Firing` for requeue), never falling through to approval; only a payload whose kind is the approval-timeout kind runs `approvalTimeoutFireAction`. This preserves the existing `runWorkflowTimerWorker` wiring (`Worker.hs:119`, `Scheduler.hs:117-118`).

Milestone 3 — kioku errors stop vanishing. Scope: `shikigami-core/src/Shikigami/Agent/Workflow.hs`, `shikigami-core/src/Shikigami/Agent/Run.hs`. At the end, a kioku write failure is logged (and counted) rather than discarded.

At each discard site, replace `_ <-`/`void` with an inspection that logs on `Left StoreError`. In `Workflow.hs`: `openSession` (line 261), `failSession` (line 377), `recordLearning` (line 589), `completeSession` (line 610) each already run `runKioku deps action :: IO (Either StoreError a)`; bind the result and, on `Left err`, `hPutStrLn stderr` a line naming the operation, the agent, and the run's idempotency key (and, if a metrics handle is available on `AppEnv`, increment a `shikigami.kioku.write_error` counter — `AppEnv` carries `metrics :: Maybe …`; keep it optional). `openSession` returning failure is the most consequential: the run continues with a session that was never persisted, so at minimum it must be loud; do not change control flow (throwing here would convert a memory outage into a run failure — out of scope), just make it visible. In `Agent/Run.hs` (the non-workflow `runAgentWithMemory` seam, lines 63/97/115), do the same. Where a call is genuinely fire-and-forget by design, keep it but log — never silently discard.

Milestone 4 — loud loading and enqueue hardening. Scope: the three CLI loaders, `Worker.hs` schedule extraction, `Shikigami/Trigger/Enqueue.hs`, plus the UUIDv5 helpers. At the end, load failures are visible and refuseable, and the enqueue path is idempotent and total.

Add a shared loud loader. Introduce `loadAgentsLoud :: FilePath -> Bool -> IO [AgentDecl]` in a small shared module (or in `Shikigami.Agent.Loader`) that maps `loadAgent` over the directory, and for each `Left err` logs `[load] FAILED <file>: <err>` to stderr; it prints a summary `[load] loaded N of M manifests (K failed)`; when the `Bool` strict flag is set and `K > 0`, it exits non-zero (`exitFailure`) before the service starts. Replace the three copies of `loadAgents` (Worker.hs:45-49, Scheduler.hs:77-81, ConsumeStream.hs:90-94) with calls to it, wiring a `--strict` CLI flag (default off, preserving current lenient behavior) through `runWorkerCmd`, `runSchedulerCmd`, `runConsumeStream`/`runConsumeEvents`. In the worker's schedule extraction `scheduleFor` (Worker.hs:215-219) and the scheduler CLI's `parseScheduleAgent`, make an unparseable cron loud: log `[schedule] agent <name> has invalid cron: <err>` (the scheduler CLI already errors hard here via `ioError` at Scheduler.hs:63-64; the worker's `scheduleFor` silently drops — make it log before dropping, and under strict mode refuse to start).

Enqueue hardening in `Shikigami/Trigger/Enqueue.hs`: make `runQueueName` total (return via a top-level `let`/`case` that is proven at the call site, or keep `error` but only as an unreachable-by-construction with a comment — prefer a `parseQueueName` on a known-good literal wrapped so the partiality is confined; simplest acceptable fix: keep it but add a test asserting it is `Right`). Remove the per-enqueue `createQueue` from `enqueueRunJob` (Enqueue.hs:55), relying on docs/plans/18's `ensureRunQueue` called once at startup (if 18 has not landed, add `ensureRunQueue` here — MasterPlan integration point). Make `enqueueAddressedRun` idempotent or delete it in favor of `enqueueAddressedRunWithKey`: its `now`-bearing key (Enqueue.hs:66-67) means two calls for the same logical event produce two runs; the only caller is the `enqueue-run` CLI (`EnqueueRun.hs:29`), so change that caller to pass a stable key (e.g. derived from the agent and a payload hash) and drop the non-deterministic variant. In `runJobFromEnvelope` (Enqueue.hs:34-48), stop silently backdating: on unparseable `occurredAt`, log and use `getCurrentTime` (or reject the envelope), not the Unix epoch. Fix the UUIDv5 name bytes in `deterministicOutboxIdForMessage` (Workflow.hs:555-559), `scheduleTimerId` and `scheduleFiredEventId` (Scheduler.hs:66-69,74-77) to encode the text as UTF-8 (`Data.Text.Encoding.encodeUtf8` then `ByteString.unpack`) instead of `fmap (fromIntegral . fromEnum) . Text.unpack`, which truncates each `Char` to its low byte and can collide for non-ASCII agent names.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikigami` inside `nix develop`.

Edit per Plan of Work in milestone order; after each:

```bash
nix develop -c cabal build all
```

Create `shikigami-core/test/Shikigami/RoutingAndLoadingSpec.hs` exporting `tests :: TestTree`; extend `shikigami-core/test/Shikigami/SchedulerSpec.hs` with catch-up cases. Add `Shikigami.RoutingAndLoadingSpec` to `other-modules` of `test-suite shikigami-core-test` in `shikigami-core/shikigami-core.cabal`, and register it in `shikigami-core/test/Main.hs` (SchedulerSpec is already registered).

```bash
nix develop -c cabal test shikigami-core-test --test-show-details=streaming
```

Expected transcript excerpt:

```text
RoutingAndLoading
  schedule job with addressed-looking payload routes to agent-run:  OK
  event job with addressed payload routes to conversation:          OK
  undecodable event payload for a conversation agent dead-letters:  OK
  loadAgentsLoud reports and counts the broken manifest:            OK
  strict mode fails when a manifest fails to load:                  OK
Scheduler
  ...
  waking a day late arms exactly one future run (SkipMissed):       OK
  failed schedule enqueue is not treated as an approval timeout:    OK
```

Then the full suite:

```bash
nix develop -c cabal test all
```

Manual check of loud loading (uses the checked-in broken manifest):

```bash
cabal run shikigami -- worker --agents agents --strict 2>&1 | head
# expect: "[load] FAILED agents/broken.dhall: ..." then "[load] loaded N of M ... (1 failed)"
# and a non-zero exit under --strict
```


## Validation and Acceptance

Routing (fails before): a table-driven pure test over `routeRunJob`. A `RunJob { triggerKind = TriggeredBySchedule, triggerPayload = <an object that decodes as AddressedMessage> }` must yield `AgentRunRoute` — before this plan `handleRunJob` would send it to the conversation path (assert via the routing function, which did not exist before, so this is the fails-before evidence for the new behavior; also add a regression asserting a genuine `TriggeredByEvent` addressed payload yields `ConversationRoute`). Construct the addressed-looking payload from the `AddressedMessage` fields used in `test/Main.hs`.

Scheduler catch-up (fails before): in `SchedulerSpec`, arm an agent on `* * * * *` with `now` set to a fixed instant, then invoke the fire action with a `TimerRow` whose `dueAt` is 24 hours in the past under `SkipMissed`. Assert exactly one run job is enqueued and the newly-armed timer's `fireAt` is `> now`. The fails-before counterpart drives the current `FireAll`-equivalent path and observes many enqueues draining across passes. Read the queue with the pgmq test helpers the suite already uses. Also assert: a schedule fire whose `enqueueScheduledRun` fails (point the pool at a closed connection or use a fire action stub) leaves the timer for requeue and does not invoke `approvalTimeoutFireAction` — before the change the `Nothing` fell through to the approval path.

Loud loading (fails before): call `loadAgentsLoud "agents" False` and assert the returned list excludes `broken` while a captured stderr contains `FAILED agents/broken.dhall`; call with strict `True` and assert it exits (test via a variant returning `Either` count so the assertion does not kill the test process, or run the CLI as a subprocess and check the exit code). Before this plan, `loadAgents` returns the same filtered list with no log — the visibility is the new, testable behavior.

kioku loudness (fails before, where observable): drive `openSession`/`recordLearning` against an `AppEnv` whose store pool has been released so the kioku write returns `Left StoreError`; assert the run still returns but a captured stderr names the failed operation. This proves the discard sites now surface failures.

Enqueue hardening: unit tests asserting `runQueueName` is a valid queue (no partial crash), that `runJobFromEnvelope` on an envelope with a bogus `occurredAt` does not produce the epoch, that the addressed enqueue for one logical event twice yields one stable idempotency key, and that `scheduleTimerId "café" t` differs from `scheduleTimerId "caf\9" t`-style near-collisions (UTF-8 bytes, not truncated `fromEnum`).

Operationally: run the scheduler, stop it for several minutes on a `* * * * *` agent, restart it, and observe exactly one enqueued run rather than one per missed minute (`SELECT count(*) FROM pgmq.q_shikigami_run_jobs`).


## Idempotence and Recovery

All changes are code-only; no migrations. Re-running builds and tests is safe (each DB-backed test gets a fresh database). The routing and scheduler changes are safe to deploy while jobs and timers are in flight: existing queued jobs still decode and route (now correctly), and existing armed timers fire once and re-arm under the new policy — a one-time drain of any pre-existing stale backlog may occur on first upgrade unless operators clear it, which is noted here as expected. The loud-loading default stays lenient (`--strict` is opt-in), so upgrading does not suddenly refuse to start. Enqueue-key changes affect only newly produced jobs; in-flight jobs with old keys are unaffected. Rolling back reintroduces the silences but is otherwise clean.


## Interfaces and Dependencies

Libraries and why: aeson (`fromJSON` for the routing decision), keiro (`Keiro.Timer` — `TimerRow`, `scheduleTimerOnceTx`, and the timer worker used by the scheduler; a past-due timer fires late with no built-in catch-up, verified keiro `src/Keiro/Timer.hs`), shibuya-core (`Shibuya.Core.Ack.AckDecision`/`DeadLetterReason (InvalidPayload, PoisonPill)` for route-error dead-lettering), `base`/`text` (`Data.Text.Encoding.encodeUtf8` for the UUIDv5 fix; `System.Exit.exitFailure` for strict mode; `System.Environment`/`optparse` for the `--strict` flag), the existing `Shikigami.Agent.Loader.loadAgent`.

Signatures that must exist at the end (full module paths):

```haskell
-- shikigami-core/src/Shikigami/Worker.hs
data Shikigami.Worker.RunRoute = ConversationRoute !AddressedMessage | AgentRunRoute | RouteError !Text
Shikigami.Worker.routeRunJob :: RunJob -> RunRoute

-- shikigami-core/src/Shikigami/Trigger/Scheduler.hs
data Shikigami.Trigger.Scheduler.CatchUpPolicy = SkipMissed | CoalesceToLatest | FireAll
-- SchedulerEnv gains: catchUpPolicy :: !CatchUpPolicy
Shikigami.Trigger.Scheduler.armNextRun ::
  (Store :> es, IOE :> es) => CatchUpPolicy -> CronSchedule -> Text -> UTCTime -> Eff es ()

-- shikigami-core/src/Shikigami/Agent/Loader.hs (or a shared CLI module)
Shikigami.Agent.Loader.loadAgentsLoud :: FilePath -> Bool -> IO [AgentDecl]

-- shikigami-core/src/Shikigami/Trigger/Enqueue.hs
-- enqueueRunJob no longer calls createQueue; runJobFromEnvelope no longer backdates to epoch;
-- enqueueAddressedRun removed or made deterministic. Coordinate ensureRunQueue with docs/plans/18.
```

Integration points (from docs/masterplans/3): docs/plans/17 and this plan both edit `Shikigami/Worker.hs` — 17 owns the ack/retry taxonomy, this plan's `RouteError` consumes it; whichever lands second reconciles `handleRunJob`. docs/plans/18 and this plan both edit `Shikigami/Trigger/Enqueue.hs` — 18 owns `enqueueRunJobTx`/`ensureRunQueue`, this plan removes the per-enqueue `createQueue` and hardens the IO helpers; the `createQueue` removal depends on `ensureRunQueue` existing (add it here if 18 has not landed). Per-agent load-state persistence is explicitly deferred to docs/plans/23 (MasterPlan 4); this plan only stops the silence.
