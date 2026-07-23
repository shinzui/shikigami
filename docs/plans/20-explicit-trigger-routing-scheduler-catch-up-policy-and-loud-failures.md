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

After this plan, every `RunJob` carries an explicit orchestration-route discriminator
separate from its trigger/audit kind; payload decoding validates the selected route but
never chooses it. The scheduler applies a Settei-configured catch-up policy, critical
kioku failures propagate to the workflow/worker retry taxonomy, explicitly best-effort
writes are logged/counted, and agent/cron load failures are loud with strict startup
available.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Prerequisites: plans 36/37 and plans 17/18 complete.
- [ ] Milestone 1: add an explicit `RunRouteKind` discriminator to `RunJob`; producers set it; payload decode only validates the selected route; typed mismatch/decode failures dead-letter; compatibility test for old jobs.
- [ ] Milestone 2: `CatchUpPolicy` in the scheduler; `armNextRun`/`scheduleFireAction` coalesce missed ticks; `scheduleFireAction` no longer falls through to the approval fallback on non-schedule payloads; tests.
- [ ] Milestone 3: critical kioku open/record/complete/fail errors propagate to retry/failure; only explicitly best-effort operations may log/count and continue; tests cover both classes.
- [ ] Milestone 4: canonical `AgentLoadReport`/`loadAgentsReport` plus loud/strict loading across the three CLI commands; unparseable-cron loudness in `Worker.hs` schedule extraction.
- [ ] Milestone 4 (hardening): enqueue-path fixes — idempotent addressed key, drop per-enqueue `createQueue`, epoch fallback, UUIDv5 non-ASCII bytes, partial `error` in `runQueueName`.
- [ ] Register new/extended specs in `shikigami-core.cabal` and `shikigami-core/test/Main.hs`; `cabal build all` and `cabal test all` green under `nix develop`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Add an explicit `RunRouteKind` (`AgentWorkflowRoute` or
  `ConversationWorkflowRoute`) to `RunJob`; keep `triggerKind` as audit/provenance.
  Payload decoding validates the selected route but never chooses it.
  Rationale: `TriggeredByEvent` is not inherently synonymous with a conversation, so
  reusing trigger kind would preserve a subtler inference bug. A new optional/defaulted
  field preserves old queued-job decoding while producers become explicit.
  Date: 2026-07-22
- Decision: Kioku session open/record/completion failures that affect run truth are
  critical and propagate into plan 17's retry/failure taxonomy. Only named best-effort
  enrichment writes may continue after structured logging/metrics.
  Rationale: logging a missing session or durable learning while returning success is
  still a lie, not error handling.
  Date: 2026-07-22

- Decision: Default scheduler catch-up policy is skip-missed (arm only the next future tick); make it configurable via `CatchUpPolicy` with a coalesce-to-latest alternative.
  Rationale: A cron agent's value is "run about now", not "run once for every minute I was offline". Verified storm: `scheduleFireAction` re-arms from the fired `dueAt` (`Scheduler.hs:101-102` → `armNextRun cron agent dueAt`), and `nextDue` steps one interval, so a backlog drains one stale run per worker pass with distinct idempotency keys `agent:sched:<minute>` (`Enqueue.hs:101`). Skip-missed advances `nextDue` past `now` before arming.
  Date: 2026-07-08

- Decision: Only stop the silence around agent/cron load failures here (per-file log, count,
  Settei `agents.strict` refusal to start); do not persist per-agent load state.
  Rationale: Durable per-agent load/lifecycle state belongs to docs/plans/23-agent-lifecycle-control-with-meibo-principals.md (MasterPlan 4), which introduces the meibo principal model. Building a throwaway store here would create migration debt. This is a declared MasterPlan integration boundary.
  Date: 2026-07-08

- Decision: This plan owns the canonical agent-directory traversal and load-report API;
  plans 30, 33, and 23 consume it for inspection, enabled filtering, and durable state.
  Rationale: those plans previously proposed separate directory walks and result shapes.
  One report preserves failed entries for operators/persistence while still exposing the
  successfully loaded declarations to runtimes.
  Date: 2026-07-22

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

Milestone 1 — explicit routing. Scope: the public `RunJob` DTO and worker package. At
the end, producers set `RunRouteKind`, the worker selects only from that field, and an
incompatible/undecodable payload is dead-lettered rather than silently misrouted. Old
rows decode via an explicit compatibility default and are covered by a golden fixture.

Add a pure decision:

```haskell
data RunRoute = ConversationRoute !AddressedMessage | AgentRunRoute | RouteError !Text

routeRunJob :: RunJob -> RunRoute
routeRunJob job = case routeKind job of
  ConversationWorkflowRoute ->
    case Aeson.fromJSON (triggerPayload job) of
      Aeson.Success addressed -> ConversationRoute addressed
      Aeson.Error err -> RouteError (Text.pack err)
  AgentWorkflowRoute -> AgentRunRoute
```

Rework `handleRunJob` (Worker.hs:132-141) to `case routeRunJob job of` → `ConversationRoute a -> runConversationAgent env job a`; `AgentRunRoute -> runOneAgent env job`; `RouteError e ->` route through plan 17's `classifyOutcome`/ack taxonomy. A conversation agent whose addressed payload does not decode is a permanent invalid-payload error; do not construct an ad-hoc `AckDecision` because plan 17 is a hard dependency.

Milestone 2 — scheduler catch-up policy. Scope: `shikigami-core/src/Shikigami/Trigger/Scheduler.hs`. At the end, waking late arms exactly one future tick, and a failed schedule fire is not misread as an approval timeout.

Add `data CatchUpPolicy = SkipMissed | CoalesceToLatest | FireAll` and a field on `SchedulerEnv` (default `SkipMissed`). Change `armNextRun` (Scheduler.hs:79-90) to advance to the first strictly-future due time under `SkipMissed`/`CoalesceToLatest`: iterate `nextDue` from `now` until the result is `> now` (bounded loop; `nextDue` is strictly increasing), and arm that. Under `FireAll`, keep today's behavior. In `scheduleFireAction` (Scheduler.hs:92-103), re-arm using the policy: `SkipMissed` arms the next future tick from `now` (not from the fired `dueAt`), so a backlog collapses to a single future run; `CoalesceToLatest` fires the current tick once and arms the next future one (same result at minute granularity, but explicit). Fix the fallback ambiguity: replace `shikigamiTimerFallback` (Scheduler.hs:105-109) with an explicit dispatch on the timer payload's `kind` — if it parses as a schedule payload, run the schedule action and treat its `Nothing` (enqueue failure) as a genuine failure to retry (return `Nothing` so keiro leaves the timer `Firing` for requeue), never falling through to approval; only a payload whose kind is the approval-timeout kind runs `approvalTimeoutFireAction`. This preserves the existing `runWorkflowTimerWorker` wiring (`Worker.hs:119`, `Scheduler.hs:117-118`).

Milestone 3 — kioku errors stop vanishing. Scope: the core workflow/run modules. At
the end, critical writes propagate as typed transient/permanent failures and only
documented best-effort enrichment may log/count and continue.

Classify session open, required learning record, fail-session, and completion updates as
truth-bearing. Convert `Left StoreError` into the typed failure path consumed by plan 17
so the run cannot report success without its durable session/memory outcome. If a call
is genuinely best-effort, name that policy in the function/type and emit structured
error metrics/logs. There are no bare `_ <-`/`void` discard sites.

Milestone 4 — loud loading and enqueue hardening. Scope: the three CLI loaders, `Worker.hs` schedule extraction, `Shikigami/Trigger/Enqueue.hs`, plus the UUIDv5 helpers. At the end, load failures are visible and refuseable, and the enqueue path is idempotent and total.

Add the canonical report to `Shikigami.Agent.Loader`:

```haskell
data AgentLoadEntry
  = AgentLoaded { path :: !FilePath, declaration :: !AgentDecl }
  | AgentLoadFailed { path :: !FilePath, error :: !LoadError }
newtype AgentLoadReport = AgentLoadReport { entries :: ![AgentLoadEntry] }

loadAgentsReport :: FilePath -> IO AgentLoadReport
loadAgentsLoud :: FilePath -> Bool -> IO AgentLoadReport
loadedAgents :: AgentLoadReport -> [AgentDecl]
```

`loadAgentsReport` is the sole directory traversal and preserves every success and failure.
`loadAgentsLoud` calls it, logs `[load] FAILED <file>: <err>` per failure plus the summary,
and exits non-zero under strict mode when any failure exists. Replace the three private
copies with this function and pass `loadedAgents report` to the runtime, wiring the validated
Settei `agents.strict` setting (default `false`) through all long-running commands. Plans 30,
33, and 23 consume the report
rather than walking the directory again. In the worker's schedule extraction `scheduleFor`
and the scheduler CLI's `parseScheduleAgent`, make an unparseable cron loud and make strict
mode refuse startup.

Enqueue hardening in `Shikigami/Trigger/Enqueue.hs`: make `runQueueName` total (return via a top-level `let`/`case` that is proven at the call site, or keep `error` but only as an unreachable-by-construction with a comment — prefer a `parseQueueName` on a known-good literal wrapped so the partiality is confined; simplest acceptable fix: keep it but add a test asserting it is `Right`). Remove the per-enqueue `createQueue` from `enqueueRunJob` (Enqueue.hs:55), relying on plan 18's `ensureRunQueue` called once at startup; plan 18 is a hard dependency, so do not define a second queue-initialization helper here. Make `enqueueAddressedRun` idempotent or delete it in favor of `enqueueAddressedRunWithKey`: its `now`-bearing key (Enqueue.hs:66-67) means two calls for the same logical event produce two runs; the only caller is the `enqueue-run` CLI (`EnqueueRun.hs:29`), so change that caller to pass a stable key (e.g. derived from the agent and a payload hash) and drop the non-deterministic variant. In `runJobFromEnvelope` (Enqueue.hs:34-48), stop silently backdating: on unparseable `occurredAt`, log and use `getCurrentTime` (or reject the envelope), not the Unix epoch. Fix the UUIDv5 name bytes in `deterministicOutboxIdForMessage` (Workflow.hs:555-559), `scheduleTimerId` and `scheduleFiredEventId` (Scheduler.hs:66-69,74-77) to encode the text as UTF-8 (`Data.Text.Encoding.encodeUtf8` then `ByteString.unpack`) instead of `fmap (fromIntegral . fromEnum) . Text.unpack`, which truncates each `Char` to its low byte and can collide for non-ASCII agent names.


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
cabal run shikigami-worker -- --config config/worker-strict.yaml 2>&1 | head
# expect: "[load] FAILED agents/broken.dhall: ..." then "[load] loaded N of M ... (1 failed)"
# and a non-zero exit because agents.strict=true in the checked config
```


## Validation and Acceptance

Routing (fails before): table-drive every `RunRouteKind`/payload combination. An agent
route with addressed-looking payload remains `AgentRunRoute`; a conversation route with
invalid addressed payload is `RouteError`; trigger kind does not affect either result.
Decode a golden old job without the discriminator and prove the compatibility policy.

Scheduler catch-up (fails before): in `SchedulerSpec`, arm an agent on `* * * * *` with `now` set to a fixed instant, then invoke the fire action with a `TimerRow` whose `dueAt` is 24 hours in the past under `SkipMissed`. Assert exactly one run job is enqueued and the newly-armed timer's `fireAt` is `> now`. The fails-before counterpart drives the current `FireAll`-equivalent path and observes many enqueues draining across passes. Read the queue with the pgmq test helpers the suite already uses. Also assert: a schedule fire whose `enqueueScheduledRun` fails (point the pool at a closed connection or use a fire action stub) leaves the timer for requeue and does not invoke `approvalTimeoutFireAction` — before the change the `Nothing` fell through to the approval path.

Loud loading (fails before): call `loadAgentsLoud "agents" False` and assert the report contains an `AgentLoadFailed` entry for `broken`, `loadedAgents` excludes it, and captured stderr contains `FAILED agents/broken.dhall`; call with strict `True` and assert it exits. Before this plan, `loadAgents` returns only the filtered list with no diagnostic or preserved failure entry.

Kioku propagation: drive each truth-bearing write against an unavailable store and
assert the run does not complete successfully and plan 17 returns the expected retry/
failure decision. Separately prove an explicitly best-effort fixture logs/counts and
continues.

Enqueue hardening: unit tests asserting `runQueueName` is a valid queue (no partial crash), that `runJobFromEnvelope` on an envelope with a bogus `occurredAt` does not produce the epoch, that the addressed enqueue for one logical event twice yields one stable idempotency key, and that `scheduleTimerId "café" t` differs from `scheduleTimerId "caf\9" t`-style near-collisions (UTF-8 bytes, not truncated `fromEnum`).

Operationally: run the scheduler, stop it for several minutes on a `* * * * *` agent, restart it, and observe exactly one enqueued run rather than one per missed minute (`SELECT count(*) FROM pgmq.q_shikigami_run_jobs`).


## Idempotence and Recovery

All changes are code-only; no migrations. Re-running builds and tests is safe (each DB-backed test gets a fresh database). The routing and scheduler changes are safe to deploy while jobs and timers are in flight: existing queued jobs still decode and route (now correctly), and existing armed timers fire once and re-arm under the new policy — a one-time drain of any pre-existing stale backlog may occur on first upgrade unless operators clear it, which is noted here as expected. The loud-loading default stays lenient (`agents.strict = false`), so upgrading does not suddenly refuse to start. Enqueue-key changes affect only newly produced jobs; in-flight jobs with old keys are unaffected. Rolling back reintroduces the silences but is otherwise clean.


## Interfaces and Dependencies

Hard dependencies: plans 36/37, 17, and 18. Catch-up/strict settings are Settei values;
no scheduler or loader code reads the environment directly.

Libraries and why: aeson (`fromJSON` for the routing decision), keiro (`Keiro.Timer` — `TimerRow`, `scheduleTimerOnceTx`, and the timer worker used by the scheduler; a past-due timer fires late with no built-in catch-up, verified keiro `src/Keiro/Timer.hs`), shibuya-core (`Shibuya.Core.Ack.AckDecision`/`DeadLetterReason (InvalidPayload, PoisonPill)` for route-error dead-lettering), `base`/`text` (`Data.Text.Encoding.encodeUtf8` for the UUIDv5 fix; `System.Exit.exitFailure` for strict mode), plan 37's Settei configuration, and the existing `Shikigami.Agent.Loader.loadAgent`.

Signatures that must exist at the end (full module paths):

```haskell
-- shikigami-core/src/Shikigami/Worker.hs
data Shikigami.Worker.RunRoute = ConversationRoute !AddressedMessage | AgentRunRoute | RouteError !Text
Shikigami.Worker.routeRunJob :: RunJob -> RunRoute

-- shikigami-api/src/Shikigami/Api/RunJob.hs
data RunRouteKind = AgentWorkflowRoute | ConversationWorkflowRoute
-- RunJob gains routeKind with explicit backward-compatible decoding.

-- shikigami-core/src/Shikigami/Trigger/Scheduler.hs
data Shikigami.Trigger.Scheduler.CatchUpPolicy = SkipMissed | CoalesceToLatest | FireAll
-- SchedulerEnv gains: catchUpPolicy :: !CatchUpPolicy
Shikigami.Trigger.Scheduler.armNextRun ::
  (Store :> es, IOE :> es) => CatchUpPolicy -> CronSchedule -> Text -> UTCTime -> Eff es ()

-- shikigami-core/src/Shikigami/Agent/Loader.hs
Shikigami.Agent.Loader.loadAgentsReport :: FilePath -> IO AgentLoadReport
Shikigami.Agent.Loader.loadAgentsLoud :: FilePath -> Bool -> IO AgentLoadReport
Shikigami.Agent.Loader.loadedAgents :: AgentLoadReport -> [AgentDecl]

-- shikigami-core/src/Shikigami/Trigger/Enqueue.hs
-- enqueueRunJob no longer calls createQueue; runJobFromEnvelope no longer backdates to epoch;
-- enqueueAddressedRun removed or made deterministic. Coordinate ensureRunQueue with docs/plans/18.
```

Hard dependencies: plan 17 owns the ack/retry taxonomy consumed by `RouteError`; plan 18
owns `enqueueRunJobTx`/`ensureRunQueue`, which this plan's hardened IO helpers consume.
Downstream consumers of `AgentLoadReport`: plan 30 (operator inspection), plan 33
(enabled-agent selection), and plan 23 (durable load state/lifecycle). This plan only
reports and logs; plan 23 owns persistence.


## Revision Notes

- 2026-07-22: Made plans 17 and 18 prerequisites, promoted loading to the canonical
  `AgentLoadReport` seam, and assigned plans 30, 33, and 23 as consumers. This removes
  the prior "whichever lands first" duplication across MasterPlans 3, 4, 6, and 7.
- 2026-07-22: Replaced trigger-kind inference with an explicit route discriminator,
  made truth-bearing Kioku failures propagate, moved settings to Settei, and added the
  old-job compatibility gate.
