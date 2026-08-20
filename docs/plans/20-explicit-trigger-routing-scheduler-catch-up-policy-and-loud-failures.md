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

Shikigami is a declared-agent runtime. An agent is declared in a Dhall manifest under `agents/`;
something fires its trigger (a cron minute, a Kafka `activity.v1` record, an addressed
integration event, or a parent agent delegating); that firing becomes one JSON message called a
`RunJob` on a Postgres queue named `shikigami_run_jobs`; and a worker process drains that queue
and runs the agent. Three classes of silent misbehavior in that path still make the runtime hard
to trust, and this plan removes all three.

**Routing is guessed, not declared.** The worker decides whether a job is a *conversation turn*
(a back-and-forth with a human through the danwa conversation service) or an *ordinary agent run*
by trying to JSON-decode the job's payload as an addressed chat message and seeing whether it
works — `dispatchRunJob` in `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs:103-107`. The
job already carries a `triggerKind` field saying where it came from, and the producer already
knows which of the two workflows it meant; neither is consulted. A schedule or stream job whose
payload happens to look like an addressed message is silently run as a conversation, and a
genuinely addressed payload that fails to decode (a producer bug) is silently run as an ordinary
agent run instead of being reported.

**The scheduler has no catch-up policy.** After downtime it replays every missed cron minute one
at a time. A `* * * * *` agent that was offline for a day produces 1440 stale runs, each with a
distinct idempotency key, so nothing deduplicates them.

**A family of errors is swallowed whole.** Kioku (the agent memory and session store) session
opens, learning records, and session completions have their `Either StoreError _` results
discarded with `_ <-` and `void` in the durable agent-run workflow, so a run can report success
having opened no session and persisted no memory. An agent manifest with a bad cron expression
loads fine and then never schedules, with nothing said. And nothing yet lets an operator say
"refuse to start if any manifest failed to load".

After this plan, every `RunJob` carries an explicit route discriminator that is separate from its
trigger/audit kind; payload decoding validates the chosen route but never chooses it, and a
mismatch dead-letters with a named reason instead of being run as the other kind of thing. The
scheduler applies a configured catch-up policy, so waking a day late produces one run and not
1440. Truth-bearing kioku failures propagate into the worker's existing retry/dead-letter
taxonomy instead of being discarded. Manifest and cron load failures are reported through the
structured logger, and a new `agents.strict` setting makes them fatal at startup.

You can see each of these working: `cabal test` gates them, and the scheduler change is visible
end-to-end by stopping the scheduler for several minutes against a `* * * * *` agent, restarting
it, and counting rows in `pgmq.q_shikigami_run_jobs`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-20T04:00:00Z) Prerequisites verified against the tree: plans 17, 18, 36, 47, and 33
      are complete; plan 37 is complete for everything this plan touches (its one open item is
      `shikigami-migrate`, handed to plan 38, and is unrelated here).
- [x] (2026-08-20T03:25:00Z) Milestone 4 (report slice, landed through plan 33): canonical
      `AgentLoadEntry`/`AgentLoadReport`, `loadAgentsReport`, `loadAgentsLoud`, and `loadedAgents`
      in `shikigami-core/src/Shikigami/Agent/Loader.hs`; all four long-running worker roles call
      `loadAgentsLoud … False` and then plan 33's `enabledAgentsFromReport`.
- [x] (2026-08-20T05:10:00Z) Milestone 1: added `RunRouteKind` to `RunJob` with an ADR-0011-style
      omit-when-legacy codec; set it explicitly in all four producers plus the `enqueue-run`
      operator path (new `--conversation` flag); `routeRunJob` decides from the field alone;
      `RouteError` dead-letters through the new named `routeErrorJobOutcome`; `WireCompatSpec`
      keeps its captured bytes and gains legacy-decode and explicit-route cases; `WorkerSpec`
      gains the routing table and an end-to-end route-error DLQ case.
- [x] (2026-08-20T06:05:00Z) Milestone 2: `CatchUpPolicy` in `Shikigami.Trigger.Schedule`;
      `SkipMissed` default wired through `AppConfig` (`scheduler.catch_up`,
      `SHIKIGAMI_SCHEDULER_CATCH_UP`) into both `SchedulerEnv` construction sites;
      `scheduleFireAction` re-arms from `now` under `SkipMissed`; explicit timer-kind dispatch
      replaces the try-then-fall-through composition; failed enqueues and unknown timer kinds are
      logged; `SchedulerSpec` gains five cases; `docs/operations/configuration.md` and
      `config/shikigami.example.yaml` document the key.
- [x] (2026-08-20T07:05:00Z) Milestone 3: truth-bearing kioku failures in
      `Shikigami.Agent.Workflow` propagate into the existing `AgentRunFailure` / `JobOutcome`
      taxonomy — an unreachable store rethrows into the workflow driver's `Error StoreError`
      (`RetryDefault`), a refused command journals a `StepRefused` that becomes
      `PermanentAgentRunFailure` (`Dead`); the one best-effort write is renamed
      `recordFailureLearningBestEffort` and logs `agent.memory.best_effort_failed`;
      `Shikigami.Agent.Run` gets the same treatment at its own severity (a `Left` naming the write,
      stderr for the best-effort one). `AgentWorkflowSpec` and `WireCompatSpec` gain cases.
- [x] (2026-08-20T07:55:00Z) Milestone 4 (remaining): `loadAgentsLoud` and
      `enabledAgentsFromReport` take a `Shikigami.Log.Logger` and emit
      `agents.manifest.load_failed` / `.loaded` / `.strict_refused` / `.disabled`; `loadAgentsIn`
      deleted; the Settei `agents.strict` key (`SHIKIGAMI_AGENTS_STRICT`, default `false`) is wired
      into all four worker roles; an unparseable cron is resolved once at boot by the new
      `Shikigami.Workers.Config.schedulerSchedules`, which logs `scheduler.cron.invalid` per
      offender and refuses under the same strict switch — the scheduler process's `ioError` is
      gone, so both processes report identically. Tested in `AgentLoaderSpec` and `SchedulerSpec`,
      documented in `docs/operations/configuration.md` and `config/shikigami.example.yaml`.
- [x] (2026-08-20T08:45:00Z) Milestone 4 (hardening): `enqueueAddressedRun` is gone and
      `shikigami enqueue-run` derives a stable key with the new
      `Shikigami.Trigger.Enqueue.addressedRunKey` (or takes one through `--key`); the per-enqueue
      `createQueue` is gone and `runSchedulerCmd` and `runEnqueueRun` reconcile the queue at
      startup; `runJobFromEnvelope` takes the resolved occurrence and the stream consumer logs
      `stream.envelope.occurred_at_invalid` before substituting its own clock; all six UUIDv5 sites
      hash through the new `Shikigami.Id.Name.nameBytes`; a new
      `shikigami-core/test/Shikigami/EnqueueHardeningSpec.hs` covers all of it including the
      `runQueueName` literal.
- [x] (2026-08-20T08:45:00Z) Registered `Shikigami.EnqueueHardeningSpec` in
      `shikigami-core/shikigami-core.cabal` and `shikigami-core/test/Main.hs` (the other suites
      extended already-registered modules, and `shikigami-workers`'s needed no new module).
      `nix develop -c cabal build all` and `nix develop -c cabal test all -j1` green.
- [ ] `just keiro-gate` green; final documentation pass and ADR distillation.
- [ ] Update `docs/operations/configuration.md`, `config/shikigami.example.yaml`, and
      `docs/architecture/shikigami-domain-inventory.md` for the new keys and the new `RunJob`
      field; write ADR 0012 for the route discriminator and its compatibility rule.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-08-20: **The plan's central scheduler bug claim was wrong, and the real defect is
  narrower.** The plan asserted that a failed schedule enqueue is misread as an approval timeout
  because `shikigamiTimerFallback` falls through on `Nothing`. Both timer payloads are guarded by
  their own `kind` discriminator: `parseApprovalTimeoutPayload`
  (`shikigami-core/src/Shikigami/Agent/Approval.hs:197-202`) returns `Nothing` for anything whose
  `kind` is not `shikigami.approval-timeout`, and a schedule payload's kind is
  `shikigami.schedule`. So `approvalTimeoutFireAction` on a schedule row returns `Nothing`
  immediately and signals no awakeable. No approval is ever wrongly timed out. What is actually
  wrong is that `scheduleFireAction`'s `Left _ -> pure Nothing`
  (`shikigami-workers/src/Shikigami/Trigger/Scheduler.hs:99`) throws away the `UsageError` and
  makes a failed enqueue indistinguishable, at the composition point, from "not a schedule
  timer" — a silence, which is this plan's actual subject. Milestone 2 is re-scoped accordingly.
- 2026-08-20: **`SkipMissed` needs no loop.** The plan proposed iterating `nextDue` from `now`
  until the result is strictly future. `nextDue` already does exactly that: it starts at
  `nextWholeMinute now` and steps one minute at a time until the cron matches, bounded to one leap
  year (`shikigami-core/src/Shikigami/Trigger/Schedule.hs:32-47`). `nextDue cron now` *is* the
  first strictly-future tick. The whole fix is to re-arm from `now` instead of from the fired
  `dueAt` (`Scheduler.hs:101-102`).
- 2026-08-20: **`RunJob` is journaled, and its bytes are pinned by a live test.** The agent-run
  workflow records the job as the result of its `ingest-job` step
  (`shikigami-core/src/Shikigami/Agent/Workflow.hs:218`), and `Shikigami.Agent.Delegate.delegate`
  writes `Aeson.toJSON childJob` straight into a child workflow's journal
  (`shikigami-core/src/Shikigami/Agent/Delegate.hs:64-72`). `Shikigami.WireCompatSpec` pins the
  exact pre-upgrade bytes as a captured literal and asserts "the payload is the job itself"
  (`shikigami-core/test/Shikigami/WireCompatSpec.hs:71-101`). Adding a field with a generic
  codec would fail that test and change what replays. The fix is the pattern ADR 0011 already
  established for `AgentDecl`: omit the field when it holds its compatibility default, and
  restore that default when the key is absent.
- 2026-08-20: **Plan 17 replaced the acknowledgement vocabulary this plan was written against.**
  Run jobs no longer classify into shibuya's `AckDecision`/`DeadLetterReason`. The handler is a
  `keiro-pgmq` job processor returning `Keiro.PGMQ.JobOutcome` (`Done | RetryDefault | Dead`),
  with a local `deadOutcome` helper that prefixes a reason
  (`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs:235-265`). Shibuya's `AckDecision`
  survives only on the Kafka consumer path
  (`shikigami-workers/src/Shikigami/Trigger/Consumer.hs:420`). `RouteError` therefore produces a
  `Dead` outcome, not an `AckDecision`.
- 2026-08-20: **The conversation path is already honest about kioku errors.** Every
  `runKioku` call in `shikigami-core/src/Shikigami/Agent/Conversation.hs` binds its result and
  returns `Either Text …` (lines 335, 348-360, 376, 409, 488-500). Milestone 3 is scoped to
  `Shikigami.Agent.Workflow` (the durable agent-run path) and `Shikigami.Agent.Run`.
- 2026-08-20: **`Shikigami.Agent.Run` is no longer on the platform path.** Plan 36 and plan 55
  moved one-off runs into the `shikigami-agent` package; `runAgentWithMemory` now has exactly one
  caller, `shikigami-agent/src/Shikigami/Agent/Command/AgentRun.hs:70`. Its five discard sites
  (`Run.hs:65,90,99,135,162`) are a developer-harness lie rather than a production one, which
  changes their severity but not whether they get fixed.
- 2026-08-20: **The loader's directory traversal is not recursive, so there is exactly one
  expected failing fixture, not two.** `loadAgentsReport` does `listDirectory dir` and keeps
  top-level names ending in `.dhall` (`shikigami-core/src/Shikigami/Agent/Loader.hs:52-54`), so
  `agents/` yields `broken.dhall`, `danwa-heartbeat.dhall`, `heartbeat.dhall`, and
  `triage-note.dhall`. `agents/detectors/schema.dhall` is never reached. MasterPlan 3's
  "EP-4's strict mode must also expect **two** failing fixtures" note is stale and should be
  corrected when this plan lands.
- 2026-08-20: **The loader writes raw stderr lines, which contradicts plan 28's M1 rule.**
  `loadAgentsLoud` and `enabledAgentsFromReport` use `hPutStrLn stderr`
  (`Loader.hs:73,89,107`), while plan 28 M1 replaced every other stderr write in the
  long-running processes with `Shikigami.Log`'s one-JSON-object-per-line logger. All four call
  sites already build a `Log.Logger` before calling the loader
  (`Workers/Command/Worker.hs:39-40`, `Workers/Command/Scheduler.hs:39-40`,
  `Workers/Subscription.hs:29-33` and `:72-75`), so threading it in is mechanical.
- 2026-08-20: **There are no metrics to count into yet.** Plan 28's M2 is unstarted and every
  `AppEnv` in this repository is constructed with `metrics = Nothing`. Milestone 3's "log and
  count" is therefore log-only; the counter lands with plan 28.
- 2026-08-20: **Removing `createQueue` from `enqueueRunJob` has two exposed callers.** The
  worker reconciles its queue through `Keiro.PGMQ.ensureJobQueue`
  (`shikigami-workers/src/Shikigami/Workers/Registry.hs:62`) and both Kafka consumers call
  `ensureRunQueue` at startup (`Workers/Subscription.hs:42,84`), but
  `Shikigami.Workers.Command.Scheduler.runSchedulerCmd` and
  `Shikigami.Server.Command.EnqueueRun.runEnqueueRun` do neither and rely on the per-send
  `createQueue`. Both need an explicit `ensureRunQueue` before the removal.
- 2026-08-20: **There are six `fromEnum`-per-`Char` UUIDv5 sites, not three**, and one of them
  mints workflow ids. `Scheduler.hs:67,75`, `Workflow.hs:761`, `SinkOutbox.hs:187`,
  `Approval.hs:186`, and `Delegate.hs:103`. The last builds a delegated child's `WorkflowId`. For
  ASCII text `fromEnum` and UTF-8 agree byte for byte, so switching to `encodeUtf8` changes no id
  any existing manifest produces; it only separates the non-ASCII names that currently collide.
- 2026-08-20: Plan 36 had already replaced the old CLI copies with
  `Shikigami.Agent.Loader.loadAgentsIn`, so the report slice could stay in `shikigami-core` and
  the four worker-role call sites. Plan 33 needed the canonical report for enabled filtering
  before this plan's other milestones were ready, so that independently useful slice landed first;
  `agents.strict` and cron handling remain here. `loadAgentsIn` survives as a thin wrapper
  (`Loader.hs:130-131`) with no remaining caller and should be deleted by Milestone 4.
- 2026-08-20: **A kioku write answers on two layers, not one, and the plan only saw the outer
  one.** The plan describes kioku operations as returning `Either StoreError _`. They return
  `Eff es (Either SessionWriteError SessionId)` (`Kioku.Session.start`, `.complete`,
  `.failSession`) and `Eff es (Either MemoryWriteError MemoryId)` (`Kioku.Memory.record`), which
  `Shikigami.Agent.Workflow.runKioku` then wraps in its own `Either StoreError`. So the discarded
  results were hiding *two* different facts: "the store could not be reached" and "the store
  refused the command". They need opposite dispositions — the first is a transport retry, the
  second is permanent, because the same command built from the same job will be refused on every
  replay. `Kioku.Session.validateLineage`
  (`kioku-core/src/Kioku/Session.hs:205-211`, in `mori://shinzui/kioku`) is the reachable proof:
  a `RunJob` carrying `delegationDepth = Just (-1)` is rejected with `SessionInvalidLineage`
  while the store stays perfectly healthy, which is what makes the refusal layer testable without
  breaking the store the workflow journal also needs.
- 2026-08-20: **These four writes are journaled steps, so widening their result type is a wire
  change.** `open-session`, `record`, `complete`, and `fail-session` all go through `runStep`,
  which journals the step's value and decodes it again on replay. Journaling
  `Either Text SessionId` would encode as `{"Right":…}` and a workflow parked before the change,
  whose `open-session` step holds a bare session-id string, would stop replaying. This is exactly
  ADR 0011's situation a second time, so `StepResult` follows its rule: `StepProduced` encodes as
  the bare value and only `StepRefused` adds a key. `WireCompatSpec` pins it:

  ```text
  agent-run step values
    a produced value encodes exactly as the bare value:            OK
    a pre-refusal step value still decodes to the produced value:  OK
    a refusal round-trips and is distinguishable from a value:     OK
  ```

- 2026-08-20: **`cabal test all` must be run with `-j1`.** The default parallel build runs several
  database-backed suites at once against the one dev cluster, and `shikigami-workers-test` hung for
  over eleven minutes without finishing a single case; the same suite run alone finishes in about
  five seconds. Serialized, the whole gate passes:

  ```text
  Test suite conformance: PASS
  Test suite shikigami-agent-test: PASS        (8 tests)
  Test suite shikigami-api-test: PASS          (15 tests)
  Test suite shikigami-client-test: PASS       (3 tests)
  Test suite shikigami-core-test: PASS         (315 tests)
  Test suite shikigami-migrations-smoke: PASS  (2 tests)
  Test suite shikigami-migrations-test: PASS   (3 tests)
  Test suite shikigami-server-test: PASS       (20 tests)
  Test suite shikigami-workers-test: PASS      (37 tests)
  ```

- 2026-08-20: **`config/worker-strict.yaml`, referenced by the previous revision's manual check,
  does not exist.** `config/` holds `shikigami.example.yaml` and
  `worker-agent-schema-proof.yaml`. The strict-mode demonstration uses `--set` instead, which
  needs no new checked-in file.


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

- Decision: Default scheduler catch-up policy is skip-missed (arm only the next future tick);
  make it configurable.
  Rationale: A cron agent's value is "run about now", not "run once for every minute I was
  offline". Verified storm: `scheduleFireAction` re-arms from the fired `dueAt`
  (`Scheduler.hs:101-102` → `armNextRun cron agent dueAt`), and `nextDue` steps one interval, so
  a backlog drains one stale run per worker pass with distinct idempotency keys
  `agent:sched:<minute>` (`Enqueue.hs:125`). Skip-missed advances `nextDue` past `now` before
  arming.
  Date: 2026-07-08

- Decision: Only stop the silence around agent/cron load failures here (per-file log, count,
  Settei `agents.strict` refusal to start); do not persist per-agent load state.
  Rationale: Durable per-agent load/lifecycle state belongs to
  docs/plans/23-agent-lifecycle-control-with-meibo-principals.md (MasterPlan 4), which introduces
  the meibo principal model. Building a throwaway store here would create migration debt. This is
  a declared MasterPlan integration boundary.
  Date: 2026-07-08

- Decision: This plan owns the canonical agent-directory traversal and load-report API;
  plans 30, 33, and 23 consume it for inspection, enabled filtering, and durable state.
  Rationale: those plans previously proposed separate directory walks and result shapes.
  One report preserves failed entries for operators/persistence while still exposing the
  successfully loaded declarations to runtimes.
  Date: 2026-07-22

- Decision: Bundle the small enqueue-path hardening (idempotent addressed key, no per-enqueue
  `createQueue`, non-epoch occurredAt, UTF-8-correct UUIDv5 bytes, total `runQueueName`) into this
  plan's Milestone 4 rather than a separate plan.
  Rationale: They are one-to-few-line correctness fixes in the same trigger/enqueue surface this
  plan already owns, too thin to be their own ExecPlan. `createQueue` removal coordinates with
  docs/plans/18's `ensureRunQueue`, which has since landed.
  Date: 2026-07-08

- Decision: `RunRouteKind` lives in `shikigami-core/src/Shikigami/Agent/RunJob.hs` beside
  `RunJob`, not in `shikigami-api`.
  Rationale: the previous revision named `shikigami-api/src/Shikigami/Api/RunJob.hs`, a path that
  plan 36 never created. `shikigami-api` holds only the HTTP surface (`Shikigami.Api`,
  `Shikigami.Api.Problem`, `Shikigami.Api.OpenApi`, `Shikigami.Health.Api`), and
  `shikigami-workers` may not depend on it — `Shikigami.PackageArchitectureSpec` enforces exactly
  that edge. The job contract has lived in `shikigami-core` since plan 36.
  Date: 2026-08-20

- Decision: `RunRouteKind` has a third constructor, `InferredLegacyRoute`. A `RunJob` with no
  `routeKind` key decodes to it; a `RunJob` holding it encodes without the key; and the worker
  handles it by reproducing today's duck-typed decode while logging
  `worker.job.route_inferred` at warning level.
  Rationale: `RunJob` crosses two durable boundaries — the PGMQ queue and the workflow journal —
  and `Shikigami.WireCompatSpec` pins its bytes as a captured literal. ADR 0011 already settled
  the rule for exactly this situation on `AgentDecl`, and reusing it keeps the fixtures valid.
  Defaulting silently to `AgentWorkflowRoute` instead would quietly reroute any conversation job
  queued before the deploy; a named legacy constructor makes the transitional branch greppable,
  observable in the log, and deletable once the warning stops appearing.
  Date: 2026-08-20

- Decision: A `RouteError` produces `Keiro.PGMQ.Dead` through the handler's existing
  `deadOutcome "invalid_route_payload"`, not a shibuya `AckDecision`.
  Rationale: plan 17 moved run-job acknowledgement onto `keiro-pgmq`'s typed `Job`/`JobOutcome`
  abstraction with a reconciled DLQ; shibuya's ack vocabulary now applies only to the Kafka
  consumer. Constructing an `AckDecision` here would not type-check against the handler.
  Date: 2026-08-20

- Decision: The catch-up policy has two constructors, `SkipMissed` (default) and `FireAll`. The
  previously proposed `CoalesceToLatest` is dropped.
  Rationale: `nextDue` resolves to whole minutes, and `scheduleFireAction` enqueues the tick it
  was fired for before re-arming. "Coalesce every missed tick into one" and "skip the missed ticks
  and arm the next future one" therefore produce the identical observable result — one run for the
  wake-up, then the normal cadence. Shipping two names for one behavior invites an operator to
  believe there is a distinction to reason about.
  Date: 2026-08-20

- Decision: `CatchUpPolicy` is defined in `shikigami-core/src/Shikigami/Trigger/Schedule.hs`,
  beside `CronSchedule` and `nextDue`.
  Rationale: `AppConfig` must carry the resolved value and lives in `shikigami-core`, while the
  scheduler that consumes it lives in `shikigami-workers`; core cannot depend on workers. Putting
  the type next to the cron vocabulary it qualifies keeps `Shikigami.App.Config` importing a
  domain type rather than defining one.
  Date: 2026-08-20

- Decision: Milestone 2's timer-kind dispatch is re-scoped from a correctness fix to an
  explicitness-and-diagnostics fix, and gains logging of failed schedule enqueues.
  Rationale: both timer payloads self-describe through a `kind` field and each parser rejects the
  other's, so the current try-then-fall-through composition never actually mis-fires an approval
  (see Surprises & Discoveries). The change still earns its place: it makes the dispatch say what
  it means, and it converts `Left _ -> pure Nothing` into a logged failure, which is the silence
  this plan exists to remove.
  Date: 2026-08-20

- Decision: Milestone 3 logs through `Shikigami.Log` and does not emit metrics.
  Rationale: `Shikigami.Telemetry.Metrics` does not exist; plan 28's M2 is unstarted and every
  `AppEnv` in the tree is built with `metrics = Nothing`. Inventing a counter here would be a
  second metrics surface for plan 28 to reconcile.
  Date: 2026-08-20

- Decision: The UUIDv5 name encoding lives in one new module,
  `shikigami-core/src/Shikigami/Id/Name.hs`, exporting `nameBytes :: Text -> [Word8]`, rather than
  the same `ByteString.unpack . encodeUtf8` being written six times.
  Rationale: the six sites were six copies of one convention and had drifted into one wrong answer
  together; a named function with the explanation attached is what stops the seventh copy being
  written by hand. It has to be in `shikigami-core` because both `shikigami-core` and
  `shikigami-workers` mint ids, and workers may depend only on core.
  Date: 2026-08-20

- Decision: `runJobFromEnvelope` takes the resolved occurrence as a parameter and stays pure;
  `envelopeOccurredAt` exposes the parse, and the stream consumer resolves and logs before opening
  the inbox transaction. `inboxHandler`, `processActivity`, `processDecodedActivity`, and
  `processActivityRecord` gain the parameters that requires.
  Rationale: the plan proposed making `runJobFromEnvelope` an `IO` action taking a logger, but it
  is called from inside a Hasql transaction, where neither a clock read nor a log write belongs.
  Resolving before the transaction is the shape `eventInboxHandler` already uses with `receivedAt`,
  and it keeps the job builder a pure function of its inputs.
  Date: 2026-08-20

- Decision: An unparseable cron is governed by `agents.strict`, not by a second key of its own.
  Rationale: the operator intent is one intent — "refuse to start on a declaration this process
  cannot act on". A manifest that will not load and a scheduled agent whose cron will not parse are
  the same kind of mistake reaching the same deploy, and splitting them into `agents.strict` and
  some `scheduler.strict` would make an operator set two keys to express one decision. The
  documentation row for `agents.strict` names both cases.
  Date: 2026-08-20

- Decision: Cron resolution moves out of `schedulerEnv` into
  `Shikigami.Workers.Config.schedulerSchedules`, called once by the worker's composition root, and
  `WorkerEnv` gains the resolved `schedules` map.
  Rationale: `schedulerEnv` is a pure function called on every timer pass, which is exactly why it
  could only drop a bad cron — there was nowhere to log from and nothing to refuse with. Resolving
  at boot reports each offender once, in the place a deploy watches, and makes the refusal
  possible. `Shikigami.Workers.Command.Scheduler` now calls the same function instead of its own
  `parseScheduleAgent`, so the scheduler process and the worker's timer loop report a bad cron the
  same way rather than one raising an `ioError` and the other saying nothing.
  Date: 2026-08-20

- Decision: A kioku transport failure and a kioku refusal get opposite dispositions. An
  unreachable store rethrows into the workflow driver's `Error StoreError` and becomes
  `runAgentRunWorkflow`'s `Left storeError`, which `agentJobOutcome` already maps to
  `RetryDefault`. A refused command becomes a journaled `StepRefused` that the caller turns into
  `PermanentAgentRunFailure`, which `agentJobOutcome` already maps to `Dead`.
  Rationale: the plan anticipated one failure layer and assigned it to the retrying arm. There are
  two (see Surprises & Discoveries), and retrying a refusal is pointless: the command is rebuilt
  from the same journaled `RunJob` on every attempt, so it will be refused every time. Both arms
  already exist in plan 17's taxonomy, so neither disposition needs a new outcome.
  Date: 2026-08-20

- Decision: `Shikigami.Agent.Workflow.StepResult` carries the refusal through the journal, with an
  ADR-0011-style codec, rather than the step value becoming `Either Text a`.
  Rationale: the four sites are `runStep` calls, and a step's value is journaled and decoded again
  on replay. `Either`'s derived encoding (`{"Right":…}`) would break every workflow parked with a
  bare session id in its `open-session` step. `StepProduced` therefore encodes as the bare value —
  byte-identical to what those steps already wrote — and only `StepRefused` adds a `stepRefused`
  key. The constraint this buys is that the produced type must never itself encode as an object
  carrying that key; the three uses encode as a string, a string-or-null, and an empty array, and
  the haddock says so.
  Date: 2026-08-20

- Decision: `Shikigami.Agent.Run` collapses both kioku layers into one `Text` through a local
  `kiokuAnswer` helper rather than adopting `StepResult`.
  Rationale: that module is the one-off harness `shikigami-agent-run` drives; it already returns
  `IO (Either Text AgentRunResult)`, journals nothing, and its reader is a person at a terminal
  rather than a retry classifier. A retry/permanent split there would be a distinction with no
  consumer.
  Date: 2026-08-20

- Decision: `scheduleFireAction` and `shikigamiTimerFallback` take `now` as a parameter rather
  than reading `getCurrentTime` inside. The Interfaces section's pinned
  `shikigamiTimerFallback :: SchedulerEnv -> TimerRow -> Eff es (Maybe EventId)` gains a `UTCTime`
  argument before the `TimerRow`.
  Rationale: `runSchedulerTimerWorker appEnv env now` already holds the instant keiro used to
  decide the timer was due, and both call sites (`Trigger.Timer.runTimerWorker` and
  `Command.Scheduler.runSchedulerCmd`) compute it one line earlier. Reading the clock a second
  time inside the fire action would let the re-arm disagree with the claim that produced it, and
  would make `SkipMissed` untestable: `SchedulerSpec` drives fixed instants in June 2026, so a
  wall-clock re-arm would arm a timer months away and break the existing "re-armed next schedule
  timer fired" case. With `now` threaded, the day-late scenario is an ordinary pure-ish assertion.
  Date: 2026-08-20

- Decision: `Shikigami.Agent.Approval` exports `approvalTimeoutKind`.
  Rationale: the explicit dispatch has to name the kind it is routing to. The constant already
  existed and was already the guard inside `parseApprovalTimeoutPayload`; exporting it is what
  lets the dispatch compare against the one spelling rather than repeating the string literal.
  Date: 2026-08-20

- Decision: `SchedulerEnv` gains a `logger` field alongside `catchUpPolicy`.
  Rationale: this milestone's whole subject is that a failed enqueue and an unclaimed timer kind
  say nothing. Both facts are discovered inside the fire action, which had no way to report them;
  `Shikigami.Workers.Config.schedulerEnv` and `runSchedulerCmd` both already have a logger in
  scope. `WorkerEnv` gains a matching `catchUpPolicy` field so the worker's timer loop and the
  scheduler process resolve the same key.
  Date: 2026-08-20

- Decision: The route-error dead-letter mapping is a named export,
  `Shikigami.Agent.RunJob.Worker.routeErrorJobOutcome :: Text -> JobOutcome`, rather than an inline
  `deadOutcome "invalid_route_payload"` inside `dispatchRunJob`.
  Rationale: `transientBehaviorJobOutcome` already exists in that module for exactly this reason —
  its haddock says it is "kept as a named mapping so the outcome table can pin it without
  manufacturing a full worker environment". `dispatchRunJob` needs a `WorkerEnv` carrying a kioku
  `AppEnv`, a behavior environment, and a danwa client, none of which a routing test has any use
  for. With the mapping named, `WorkerSpec` drives the real `routeRunJob` and the real outcome
  mapping against a real queue and asserts the message lands in the reconciled DLQ.
  Date: 2026-08-20

- Decision: `eventInboxHandler` decides its route through a named `eventRouteOf :: AgentDecl ->
  RunRouteKind` helper in `shikigami-workers/src/Shikigami/Trigger/Consumer.hs`, comparing the
  agent's declared `eventType` against `Shikigami.Integration.Danwa.addressedMessageEventType`.
  Rationale: the plan called for exactly this comparison; giving it a name and a haddock keeps the
  reason for the distinction ("the declaration is what asks for a conversation") at the place a
  future reader will look, instead of as a bare guard inside a `let` binding in a transaction body.
  Date: 2026-08-20

- Decision: `loadAgentsLoud` takes a `Shikigami.Log.Logger` and emits structured events rather
  than `hPutStrLn stderr`; `enabledAgentsFromReport` does the same.
  Rationale: plan 28 M1 established that every line a long-running process writes is one JSON
  object, and the loader is the last stderr writer in those processes. All four call sites already
  have a logger in scope before they call the loader.
  Date: 2026-08-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-08-20 (Milestone 4, report slice — delivered through plan 33). The canonical
  `AgentLoadReport` seam exists and is the single directory traversal for the whole repository:
  `loadAgentsReport` preserves every success and failure in filename order, `loadedAgents`
  projects the successes, and `loadAgentsLoud` reports failures and a summary. All four
  long-running worker roles use it. What this bought immediately is that a manifest typo is no
  longer invisible — `agents/broken.dhall` now reports itself. What it did not buy, and what
  remains here, is the ability to *refuse to start*: every call site passes `False` for strict
  mode because there is no configuration key to read yet.
- Lesson carried into the remaining milestones: this plan's premises decayed faster than its
  intent did. Four of its file paths, one of its dependency vocabularies, and one of its two
  headline bug claims were wrong by the time the work came up, while every user-visible outcome it
  promised is still worth delivering. Re-read the code before implementing a milestone, not after.
- (Remaining outcomes to be filled as Milestones 1–4 land.)


## Context and Orientation

Everything below names files by full repository-relative path from
`/Users/shinzui/Keikaku/bokuno/shikigami`. Terms of art are defined where they first appear.

**The package layout.** Plan 36 split this repository into seven cabal packages.
`shikigami-core` holds domain types and the durable workflows; `shikigami-workers` holds the
long-running processes (the run-job worker, the scheduler, and two Kafka consumers);
`shikigami-server` holds the HTTP API and the admin subcommands; `shikigami-agent` holds the
one-off local agent harness; `shikigami-api`, `shikigami-client`, and `shikigami-migrations` hold
the HTTP contract, its client, and schema evolution. `shikigami-cli` no longer exists. The
allowed dependency arrows are enforced as a test in
`shikigami-core/test/Shikigami/PackageArchitectureSpec.hs`: `shikigami-workers` may depend on
`shikigami-core` and on nothing else in the repository, so anything the worker and the producers
must share belongs in `shikigami-core`.

**The run-job contract.** `RunJob` is defined in `shikigami-core/src/Shikigami/Agent/RunJob.hs:19-30`
with nine fields: `agentName`, `triggerKind`, `occurredAt`, `triggerPayload` (an arbitrary
`Data.Aeson.Value`), `idempotencyKey`, and the three delegation optionals `parentSessionId`,
`parentRunWorkflowId`, `delegationDepth`. `TriggerKind` (line 14) is
`TriggeredBySchedule | TriggeredByStream | TriggeredByEvent | TriggeredByDelegation`. Both
derive their JSON codecs generically today.

Four places produce a `RunJob`:

* `Shikigami.Trigger.Enqueue.runJobFromEnvelope` (`shikigami-core/src/Shikigami/Trigger/Enqueue.hs:38-52`)
  turns a matched Kafka `activity.v1` envelope into a `TriggeredByStream` job.
* `eventInboxHandler` (`shikigami-workers/src/Shikigami/Trigger/Consumer.hs:463-482`) turns a
  matched integration event into a `TriggeredByEvent` job. This is the only producer that can
  legitimately mean "conversation": an agent declares `Trigger.Event { eventType = … }`, and the
  conversation case is exactly `eventType == Shikigami.Integration.Danwa.addressedMessageEventType`
  (`"danwa.message-addressed-to-agent"`). `agents/danwa-heartbeat.dhall` is the checked-in
  example.
* `Shikigami.Trigger.Enqueue.enqueueScheduledRun` (`Enqueue.hs:111-129`) produces a
  `TriggeredBySchedule` job for a due minute.
* `Shikigami.Agent.Delegate.delegate` (`shikigami-core/src/Shikigami/Agent/Delegate.hs:52-72`)
  produces a `TriggeredByDelegation` job for a child agent.

Plus one operator path: `shikigami enqueue-run <agent> [--payload <json>]`
(`shikigami-server/src/Shikigami/Server/Command/EnqueueRun.hs`) calls
`Shikigami.Trigger.Enqueue.enqueueAddressedRun`.

**The worker.** `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs` is a `keiro-pgmq` job
processor. `runJob` (lines 48-55) declares the queue contract; `aesonJobCodec` keeps the wire a
bare `RunJob` so decode failures dead-letter at the typed boundary before the handler runs.
`handleRunJob` (lines 60-76) renews the message's visibility lease while working and maps a
thrown `TransientBehaviorFailure` to a retry. `dispatchRunJob` (lines 103-107) is the defect:

```haskell
dispatchRunJob :: WorkerEnv -> RunJob -> IO JobOutcome
dispatchRunJob env job =
  case Aeson.fromJSON (triggerPayload job) of
    Aeson.Success addressed -> runConversationAgent env job addressed
    Aeson.Error _ -> runOneAgent env job
```

The `Aeson.Success` branch runs a danwa conversation turn; the `Aeson.Error` branch runs the
durable agent-run workflow. `triggerKind` is used only for a log field and a trace attribute
(lines 168, 276). Every outcome is a `Keiro.PGMQ.JobOutcome` — `Done`, `RetryDefault`, or `Dead`
carrying a bounded detail string — produced by `agentJobOutcome`/`conversationJobOutcome`
(lines 235-255) and the `deadOutcome` helper (lines 263-265). This is plan 17's taxonomy, and it
is what a routing error must join.

**Why the field cannot just be added.** `RunJob` crosses two durable boundaries. It sits in a PGMQ
queue as `toJSON job`, and it is written into keiro's workflow journal as the result of the
`ingest-job` step (`shikigami-core/src/Shikigami/Agent/Workflow.hs:218`) and directly by
`Shikigami.Agent.Delegate.delegate` (`Delegate.hs:64-72`). Journals outlive the binary that wrote
them and are decoded again on replay. `shikigami-core/test/Shikigami/WireCompatSpec.hs:71-101`
pins the exact byte string a `RunJob` encodes to, as a captured literal, and asserts the payload
is the job itself and not a versioned envelope. [ADR
0011](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) settled the rule
for this exact situation when plan 33 added `identity`, `memory`, and `enabled` to `AgentDecl`:
an additive, defaulted field must preserve the previous JSON shape when it holds its
compatibility default, and its decoder must restore that default when the key is absent. The
implementation there (`shikigami-core/src/Shikigami/Agent/Decl.hs:197-226`) replaces the derived
codec with hand-written instances that append `["enabled" .= False | not enabled]` and read
`value .:? "enabled" .!= True`. Milestone 1 follows it exactly.

[ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md) is the other constraint worth
knowing: the checked keiro-dsl specification under `domain/` deliberately does *not* declare the
`shikigami_run_jobs` queue, because a scaffolded workqueue would impose keiro's `{v,t,data}`
envelope on a payload this service sends bare. `domain/shikigami-agent-run.keiro:30-34`
inventories only the three `RunJob` fields the specification refers to (`agentName`,
`idempotencyKey`, `occurredAt`), so adding `routeKind` needs no specification edit — but
`just keiro-gate` still runs, and `docs/architecture/shikigami-domain-inventory.md:157-165`
describes the record's field list and must be updated to say nine fields, not eight.

**The scheduler.** `shikigami-workers/src/Shikigami/Trigger/Scheduler.hs` drives keiro *durable
timers* — rows in Postgres carrying a fire time and a JSON payload. `armNextRun` (lines 79-90)
computes `nextDue cron now` and inserts a one-shot timer at that instant through
`scheduleTimerOnceTx`. When a timer comes due, `scheduleFireAction` (lines 92-103) parses the
schedule payload, enqueues a `TriggeredBySchedule` run, and re-arms — from the *fired* `dueAt`,
not from `now`:

```haskell
      enqueued <- liftIO (enqueueScheduledRun (pool env) agent dueAt)
      case enqueued of
        Left _ -> pure Nothing
        Right _ -> do
          for_ (Map.lookup agent (schedules env)) \cron ->
            armNextRun cron agent dueAt
          pure (Just (scheduleFiredEventId agent dueAt))
```

`nextDue` (`shikigami-core/src/Shikigami/Trigger/Schedule.hs:32-47`) returns the first minute
strictly after its argument that the cron matches. Feeding it a past `dueAt` therefore yields
another past minute. Only one schedule timer exists at a time, so a backlog does not appear all at
once; instead each pass of the timer loop claims the one stale timer, fires it, and arms the next
still-stale one. The loop sleeps one second between passes
(`shikigami-workers/src/Shikigami/Trigger/Timer.hs:41`), so a day of downtime on a `* * * * *`
agent drains 1440 stale runs over roughly 24 minutes, each with a distinct idempotency key
`agent:sched:<iso8601 minute>` (`Enqueue.hs:125`) so nothing deduplicates them. Keiro's timer
layer has no catch-up policy of its own: a past-due timer is simply claimed and fired late
(`claimAndFireOne`, keiro `keiro/src/Keiro/Timer.hs:159-188`).

Two loops fire timers. The scheduler process
(`shikigami-workers/src/Shikigami/Workers/Command/Scheduler.hs`) arms every scheduled agent at
startup and then polls `runSchedulerTimerWorker`; the worker process runs the same fire action
through `Shikigami.Trigger.Timer.runTimerWorker` over the `SchedulerEnv` derived by
`Shikigami.Workers.Config.schedulerEnv` (`shikigami-workers/src/Shikigami/Workers/Config.hs:125-136`).
Both go through `shikigamiTimerFallback` (`Scheduler.hs:105-109`), which tries the schedule action
and falls through to `Shikigami.Agent.Approval.approvalTimeoutFireAction` on `Nothing`. Keiro
treats a `Nothing` from the fire action as "not fired": the row stays in `Firing` and
`requeueStuckTimers` returns it after the default 300-second TTL, with no attempt ceiling
(`defaultTimerWorkerOptions`, keiro `keiro/src/Keiro/Timer.hs:90-91`).

**Swallowed kioku errors.** Kioku is the session and memory store; its operations return
`Either StoreError _`. In the durable agent-run workflow those results are discarded at five
places in `shikigami-core/src/Shikigami/Agent/Workflow.hs`: `Session.start` at line 427 (`_ <-`,
inside `openSession`), a best-effort failure-learning `recordMemory` at 561 (`void $`),
`Session.failSession` at 569 (`void $`), `Memory.record` at 811 (`_ <-`, inside `recordMemory`),
and `Session.complete` at 845 (`void $`). A store failure at any of them means the run reports
success with no session opened, no learning persisted, or no completion recorded, and nobody is
told. The same shape appears in the one-off harness path
`shikigami-core/src/Shikigami/Agent/Run.hs` at lines 65, 90, 99, 135, and 162; that module's only
caller is now `shikigami-agent/src/Shikigami/Agent/Command/AgentRun.hs:70`. The conversation path
in `shikigami-core/src/Shikigami/Agent/Conversation.hs` already checks every result and needs no
change.

**Loading.** `shikigami-core/src/Shikigami/Agent/Loader.hs` is the single agent-manifest loader.
`loadAgent` (line 42) type-checks one Dhall file into an `AgentDecl` and returns `Either LoadError`.
`loadAgentsReport` (lines 51-63) is the sole directory traversal — non-recursive, filename-ordered
— and preserves both successes and failures as `AgentLoadEntry` values. `loadAgentsLoud`
(lines 67-89) reports each failure and a summary and exits non-zero under strict mode.
`loadedAgents` (91-93) projects the successes; plan 33's `enabledAgentsFromReport` (97-115) filters
by the declared `enabled` flag. All four long-running roles call `loadAgentsLoud dir False` then
`enabledAgentsFromReport`. Two gaps remain. Strict mode has no configuration source, so every call
site hard-codes `False`. And the loader still writes plain stderr text rather than
`Shikigami.Log`'s JSON lines. `loadAgentsIn` (130-131) survives with no callers.

`agents/broken.dhall` is the checked-in load-failure fixture: a manifest with a `behaviour`/
`behavior` typo. It is the only failing file the traversal reaches.

**Unparseable crons.** Two places turn a declared cron string into a schedule. The scheduler
process is already loud: `parseScheduleAgent`
(`shikigami-workers/src/Shikigami/Workers/Command/Scheduler.hs:72-78`) raises an `ioError` naming
the agent. The worker process is not: `scheduleFor` inside
`Shikigami.Workers.Config.schedulerEnv` (`Workers/Config.hs:132-136`) drops the agent with
`Left _ -> Nothing`, and its own haddock names this plan as the owner of the fix. An agent with a
bad cron therefore loads, logs nothing, and never fires from the worker's timer loop.

**Configuration.** Plan 37 put every process on one strict Settei configuration.
`shikigami-core/src/Shikigami/App/Config.hs` declares the accepted keys (`stableKey` values around
lines 581-647), the `AppConfig` record, and the `appConfig` declaration that assembles it with
`withDefault … (constant …)`. `kafka.include_agent_actors` (key at line 602, setting at 421-426,
default at 317) is the existing boolean precedent to copy for `agents.strict`. Every key is
documented in the table at `docs/operations/configuration.md:109-133` and exemplified in
`config/shikigami.example.yaml`. `shikigami-core/test/Shikigami/AppConfigSpec.hs` asserts
behaviors, not a key count, so adding keys is additive.

**Enqueue-path hardening targets**, all in `shikigami-core/src/Shikigami/Trigger/Enqueue.hs`:
`runQueueName` (32-35) crashes with `error` on an invalid literal; `runJobFromEnvelope` (38-52)
falls back to the Unix epoch when `occurredAt` will not parse, silently backdating the run;
`enqueueRunJob` (76-85) calls `createQueue` on every single send; and `enqueueAddressedRun`
(88-91) builds its idempotency key from `getCurrentTime`, so it is not idempotent — two calls for
the same logical event produce two runs. Plan 18 already added the correct pieces beside them:
`enqueueRunJobTx` (59-67) for transactional sends and `ensureRunQueue` (71-72) for one-time
startup reconciliation.

**Test infrastructure.** `shikigami-workers/test/Shikigami/SchedulerSpec.hs` exercises the
scheduler against a real Postgres through `Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase`
and already reads the run-job queue with pgmq helpers; extend it.
`shikigami-workers/test/Shikigami/Agent/RunJob/WorkerSpec.hs` covers the codec and the outcome
table without a database and is the natural home for routing cases.
`shikigami-core/test/Shikigami/WireCompatSpec.hs` owns the captured `RunJob` bytes.
`shikigami-core/test/Shikigami/AgentLoaderSpec.hs` owns loader behavior over `agents/`. Both test
suites are registered by hand: `other-modules` in the package's `.cabal` and a `tests` entry in
the suite's `Main.hs`.


## Plan of Work

**Milestone 1 — explicit routing.** Scope: `shikigami-core/src/Shikigami/Agent/RunJob.hs`, the
four producers, `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs`, and the two test suites.
At the end, every newly produced job says which workflow it is for, the worker selects only from
that field, an incompatible payload dead-letters with a named reason instead of silently running
the other workflow, and a job queued before the deploy still decodes and still behaves exactly as
it does today.

Add the discriminator beside `RunJob`, and replace `RunJob`'s derived JSON instances with
hand-written ones following [ADR 0011](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md):

```haskell
-- | Which orchestration path the producer meant. Separate from 'TriggerKind',
-- which records where the job came from for audit and tracing.
data RunRouteKind
  = AgentWorkflowRoute
  | ConversationWorkflowRoute
  | -- | No producer sets this. It is what a job enqueued before the
    -- discriminator existed decodes to, and it is handled by reproducing the
    -- old duck-typed decision. Delete it once the queue has drained and
    -- @worker.job.route_inferred@ has stopped appearing.
    InferredLegacyRoute
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
```

`RunJob` gains `routeKind :: !RunRouteKind`. Its `toJSON` emits the eight existing keys unchanged
and appends `["routeKind" .= routeKind | routeKind /= InferredLegacyRoute]`; its `parseJSON` reads
`value .:? "routeKind" .!= InferredLegacyRoute`. That keeps `WireCompatSpec`'s captured literal
byte-identical for a legacy job and keeps every parked workflow's `ingest-job` step replayable.

Add the pure decision to the worker:

```haskell
data RunRoute
  = ConversationRoute !AddressedMessage
  | AgentRunRoute
  | RouteError !Text

routeRunJob :: RunJob -> RunRoute
routeRunJob job = case routeKind job of
  AgentWorkflowRoute -> AgentRunRoute
  ConversationWorkflowRoute ->
    case Aeson.fromJSON (triggerPayload job) of
      Aeson.Success addressed -> ConversationRoute addressed
      Aeson.Error err -> RouteError (Text.pack err)
  InferredLegacyRoute ->
    case Aeson.fromJSON (triggerPayload job) of
      Aeson.Success addressed -> ConversationRoute addressed
      Aeson.Error _ -> AgentRunRoute
```

Rework `dispatchRunJob` to `case routeRunJob job of`: `ConversationRoute a -> runConversationAgent
env job a`; `AgentRunRoute -> runOneAgent env job`; `RouteError detail -> jobLog … Log.Error
"worker.job.dead_lettered" ["reason" .= ("invalid_route_payload" :: Text), "error" .= detail] >>
pure (deadOutcome "invalid_route_payload" detail)`. Log `worker.job.route_inferred` at
`Log.Warn` on the `InferredLegacyRoute` branch, carrying the resolved route, so an operator can
watch the legacy branch fall out of use.

Set the route explicitly in every producer. `runJobFromEnvelope`, `enqueueScheduledRun`, and
`Shikigami.Agent.Delegate.delegate` all set `AgentWorkflowRoute`. `eventInboxHandler` sets
`ConversationWorkflowRoute` when the matched agent's declared `eventType` equals
`Shikigami.Integration.Danwa.addressedMessageEventType` and `AgentWorkflowRoute` otherwise — the
declared event type is the honest source of the distinction, and it is available where the job is
built. `enqueueAddressedRunWithKey` takes the route as a parameter so its callers state it;
`shikigami enqueue-run` gains a `--conversation` flag that selects `ConversationWorkflowRoute`,
defaulting to `AgentWorkflowRoute`.

**Milestone 2 — scheduler catch-up policy and explicit timer dispatch.** Scope:
`shikigami-core/src/Shikigami/Trigger/Schedule.hs`,
`shikigami-core/src/Shikigami/App/Config.hs`,
`shikigami-workers/src/Shikigami/Trigger/Scheduler.hs`,
`shikigami-workers/src/Shikigami/Workers/Config.hs`,
`shikigami-workers/src/Shikigami/Workers/Command/Scheduler.hs`, and `SchedulerSpec`. At the end,
waking late arms exactly one future tick, the timer worker says out loud which kind of timer it is
handling, and a failed schedule enqueue is a logged event rather than a discarded `Left`.

Add to `Shikigami.Trigger.Schedule`:

```haskell
-- | What the scheduler does about cron minutes that passed while it was down.
data CatchUpPolicy
  = -- | Arm the first tick strictly after now. Waking a day late produces the
    -- one run for the timer that was already due, then the normal cadence.
    SkipMissed
  | -- | Arm from the tick that just fired, so every missed minute runs. This is
    -- the pre-policy behavior.
    FireAll
  deriving stock (Eq, Show)
```

Add `schedulerCatchUp :: !CatchUpPolicy` to `AppConfig` under the stable key
`scheduler.catch_up`, decoded from the strings `skip_missed` and `fire_all`, defaulting to
`skip_missed`, bound to the environment variable `SHIKIGAMI_SCHEDULER_CATCH_UP`. Follow the
`kafka.include_agent_actors` precedent for the setting, the key, the default, and the binding.

Add `catchUpPolicy :: !CatchUpPolicy` to `SchedulerEnv` (`Scheduler.hs:36-39`) and populate it in
both construction sites — `runSchedulerCmd` and `Shikigami.Workers.Config.schedulerEnv`. Change
`scheduleFireAction` to re-arm from `now` under `SkipMissed` and from the fired `dueAt` under
`FireAll`; `armNextRun` itself is already correct, because `nextDue` returns the first strictly
future match. Convert the discarded enqueue failure into a logged
`scheduler.schedule.enqueue_failed` event naming the agent, the due minute, and the error, still
returning `Nothing` so keiro leaves the timer for requeue.

Replace `shikigamiTimerFallback`'s try-then-fall-through with an explicit dispatch on the timer
payload's `kind` field: `shikigami.schedule` runs the schedule action, `shikigami.approval-timeout`
runs `Shikigami.Agent.Approval.approvalTimeoutFireAction`, and anything else logs
`scheduler.timer.unknown_kind` with the payload's kind and returns `Nothing`. Keep the exported
name and type so `Shikigami.Trigger.Timer` and `runSchedulerTimerWorker` need no change beyond the
new `SchedulerEnv` field. This is deliberately not a behavior change for well-formed timers; it is
a change from "the second action happens to reject what the first one rejected" to "the code says
which action owns which row", plus the diagnostics.

**Milestone 3 — kioku errors stop vanishing.** Scope:
`shikigami-core/src/Shikigami/Agent/Workflow.hs` and `shikigami-core/src/Shikigami/Agent/Run.hs`.
At the end there is no bare `_ <-` or `void` over a kioku result, truth-bearing failures reach the
worker's existing `Dead`/`RetryDefault` decisions, and every write that is allowed to continue
after a failure says so in its own name and logs when it does.

Classify each site. `openSession` (`Workflow.hs:414-444`), `failSession` (558-578), the required
learning record inside `recordMemory` (807-830), and `completeSession` (842-855) are
truth-bearing: a run that reports success without them is lying about its own durable record. Give
`openSession` and `recordMemory` a failing return (`Either StoreError`) and thread it into the
existing `AgentRunFailure` sum, which the workflow already returns and which
`agentJobOutcome` already maps onto `Dead`/`RetryDefault`. A `StoreError` is a transport failure,
so it maps to the retrying arm — the same treatment `agentJobOutcome`'s `Left _storeError ->
RetryDefault` already gives a store failure raised from the workflow driver. The failure-path
learning at line 561 is the one genuinely best-effort write: rename it to say so
(`recordFailureLearningBestEffort`) and log `agent.memory.best_effort_failed` when it fails rather
than discarding.

Apply the same treatment in `Shikigami.Agent.Run` at its own severity: `runAgentWithMemory`
already returns `IO (Either Text AgentRunResult)`, so a failed session open or completion becomes
a `Left` with the store error rendered, and the failure-path learning becomes an explicit
best-effort write with a message on stderr. This module is the one-off harness that
`shikigami-agent-run` drives, so its contract is a human reading a terminal, not a queue.

**Milestone 4 — loud loading, strict startup, loud crons, and enqueue hardening.** Scope:
`shikigami-core/src/Shikigami/Agent/Loader.hs`, `shikigami-core/src/Shikigami/App/Config.hs`, the
four worker roles, `shikigami-workers/src/Shikigami/Workers/Config.hs`,
`shikigami-core/src/Shikigami/Trigger/Enqueue.hs`, and the five other UUIDv5 helpers. At the end,
load failures are visible in the structured log and refusable at startup, a bad cron cannot hide,
and the enqueue path is idempotent, total, and honest about time.

Change `loadAgentsLoud :: Log.Logger -> FilePath -> Bool -> IO AgentLoadReport` and
`enabledAgentsFromReport :: Log.Logger -> AgentLoadReport -> IO [AgentDecl]` to emit
`agents.manifest.load_failed`, `agents.manifest.loaded` (with loaded and failed counts), and
`agents.manifest.disabled` through `Shikigami.Log` instead of `hPutStrLn stderr`. Keep the
strict-mode `exitFailure` after the report, so an operator sees every failure before the process
dies. Delete `loadAgentsIn`, which has no callers.

Add the stable key `agents.strict` (boolean, default `false`, environment variable
`SHIKIGAMI_AGENTS_STRICT`) to `AppConfig` and pass `Config.agentsStrict config` at all four
`loadAgentsLoud` call sites in place of the hard-coded `False`. Default `false` so upgrading does
not suddenly refuse to start a deployment that has been tolerating a broken manifest.

Make an unparseable cron loud in the worker. `Shikigami.Workers.Config.schedulerEnv` is a pure
function today, which is why it can only drop. Split the parse out into
`schedulerSchedules :: Log.Logger -> Bool -> [AgentDecl] -> IO (Map Text CronSchedule)` that logs
`scheduler.cron.invalid` per offender and, under strict mode, exits; have the worker's composition
root call it once and store the result. The scheduler process's `parseScheduleAgent` already
raises on a bad cron; convert its `ioError` into the same structured event followed by
`exitFailure` so both processes report the same way.

Enqueue hardening in `Shikigami.Trigger.Enqueue`:

* Delete `enqueueAddressedRun`. Its `getCurrentTime`-bearing idempotency key (`Enqueue.hs:88-91`)
  means two invocations for one logical event produce two runs. Its only caller is
  `shikigami enqueue-run`, which changes to call `enqueueAddressedRunWithKey` with a stable key
  derived from the agent name and a hash of the payload, and gains an optional `--key` flag for an
  operator who wants to supply one.
* Remove the per-send `createQueue` from `enqueueRunJob` (`Enqueue.hs:79`) and add
  `ensureRunQueue` to the two startup paths that were relying on it:
  `Shikigami.Workers.Command.Scheduler.runSchedulerCmd` and
  `Shikigami.Server.Command.EnqueueRun.runEnqueueRun`. The worker and both consumers already
  reconcile the queue at startup.
* Stop backdating in `runJobFromEnvelope` (`Enqueue.hs:38-52`). An envelope whose `occurredAt`
  will not parse must not silently become 1970-01-01. Make the function `IO RunJob`, use
  `getCurrentTime` for the fallback, and log `stream.envelope.occurred_at_invalid` with the
  activity id and the raw value. The call site is
  `shikigami-workers/src/Shikigami/Trigger/Consumer.hs:455`, inside a Hasql transaction, so
  compute the timestamp before the transaction and pass it in — the same shape
  `eventInboxHandler` already uses with its `receivedAt` parameter.
* Fix the UUIDv5 name bytes at all six sites — `Scheduler.hs:67,75`, `Workflow.hs:761`,
  `SinkOutbox.hs:187`, `Approval.hs:186`, `Delegate.hs:103` — replacing
  `fmap (fromIntegral . fromEnum) . Text.unpack` with
  `ByteString.unpack . Data.Text.Encoding.encodeUtf8`. `fromEnum` truncates each `Char` to its low
  byte, so `"café"` and any name differing only above U+00FF collide. For ASCII the two encodings
  are identical byte for byte, so no id any checked-in manifest produces moves; only the
  currently-colliding non-ASCII cases separate. This matters most at `Delegate.hs:103`, which
  mints a child `WorkflowId`.
* Keep `runQueueName`'s `error` but confine the partiality with a test asserting
  `parseQueueName "shikigami_run_jobs"` is `Right`. The literal is a compile-time constant; a test
  that would catch a future edit is proportionate, and threading an `Either` through every caller
  is not.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikigami`. The database
tests need the in-repo Postgres cluster from the dev shell, so prefix commands with
`nix develop -c` (or run them inside `nix develop`).

Edit per Plan of Work in milestone order. After each milestone:

```bash
nix develop -c cabal build all
```

Milestone 1 adds cases to two existing modules rather than new files:
`shikigami-workers/test/Shikigami/Agent/RunJob/WorkerSpec.hs` gains a `routeRunJob` table, and
`shikigami-core/test/Shikigami/WireCompatSpec.hs` gains the legacy-decode and unchanged-encode
cases. Both modules are already registered, so no `.cabal` or `Main.hs` edit is needed for them.

Milestone 2 extends `shikigami-workers/test/Shikigami/SchedulerSpec.hs`, also already registered.

Milestone 4's enqueue and loader cases go into a new
`shikigami-core/test/Shikigami/EnqueueHardeningSpec.hs` exporting `tests :: TestTree`, and into
the existing `shikigami-core/test/Shikigami/AgentLoaderSpec.hs`. Register the new module in
`other-modules` of `test-suite shikigami-core-test` in
`shikigami-core/shikigami-core.cabal:165-183` and add it to the `testGroup` list in
`shikigami-core/test/Main.hs`.

Run each suite as you go:

```bash
nix develop -c cabal test shikigami-workers-test --test-show-details=streaming
nix develop -c cabal test shikigami-core-test --test-show-details=streaming
```

Expected transcript excerpt once all four milestones land:

```text
RunJob
  schedule job with addressed-looking payload routes to agent-run:   OK
  event job on the danwa event type routes to conversation:          OK
  undecodable payload on a conversation route dead-letters:          OK
  a legacy job with no routeKind reproduces the old decision:        OK
  trigger kind does not affect any route:                            OK
Scheduler
  waking a day late arms exactly one future run (SkipMissed):        OK
  FireAll still arms from the tick that fired:                       OK
  a failed schedule enqueue leaves the timer for requeue:            OK
  an unknown timer kind is reported, not silently approved:          OK
wire compatibility
  a pre-upgrade run job decodes to the same value:                   OK
  the encoder still produces the pre-upgrade bytes:                  OK
  a legacy job decodes with the inferred route:                      OK
  an explicit route round-trips and adds exactly one key:            OK
AgentLoader
  loadAgentsLoud reports the broken manifest through the logger:     OK
  strict mode refuses to start when a manifest fails:                OK
EnqueueHardening
  runQueueName parses:                                               OK
  an unparseable occurredAt does not become the epoch:               OK
  the same logical event enqueues one stable idempotency key:        OK
  UUIDv5 ids separate names that differ above U+00FF:                OK
```

Then the whole suite and the specification gate:

```bash
nix develop -c cabal test all
nix develop -c just keiro-gate
```

Manual check of loud loading, using the checked-in broken manifest and no new config file:

```bash
nix develop -c cabal run -v0 shikigami-worker -- --set agents.strict=true; echo "exit=$?"
```

Observed 2026-08-20 — one JSON line per failure, a summary, a refusal, and exit code 1
(fields elided for width):

```text
{"event":"agents.manifest.load_failed","level":"error","path":"agents/broken.dhall","error":"…behaviour vs behavior…"}
{"directory":"agents","event":"agents.manifest.loaded","failed":1,"level":"error","loaded":3,"total":4}
{"directory":"agents","event":"agents.manifest.strict_refused","failed":1,"level":"error"}
exit=1
```

Without the flag the same three manifests load, the failure is still reported, and the worker
carries on — which is the point of the lenient default.

Manual check of scheduler catch-up, against the dev cluster:

```bash
nix develop -c just create-database
nix develop -c cabal run shikigami-scheduler        # let it arm agents/heartbeat.dhall, then Ctrl-C
# wait five minutes
nix develop -c cabal run shikigami-scheduler        # let it run one poll, then Ctrl-C
psql -h "$PGHOST" -d "$PGDATABASE" -c 'SELECT count(*) FROM pgmq.q_shikigami_run_jobs;'
```

Expect a count of one rather than five. Repeating with `--set scheduler.catch_up=fire_all`
reproduces the old behavior and is the fails-before demonstration.


## Validation and Acceptance

**Routing** — fails before the change. Table-drive every `RunRouteKind`/payload combination and
assert that `triggerKind` never affects the result: an `AgentWorkflowRoute` job whose payload
decodes cleanly as an `AddressedMessage` still yields `AgentRunRoute`; a `ConversationWorkflowRoute`
job whose payload is not an addressed message yields `RouteError`; a `ConversationWorkflowRoute`
job with a valid payload yields `ConversationRoute`. Today the first of those runs a conversation
turn, which is the bug. Prove the dead-letter path end-to-end by extending the existing "permanent
outcome reaches the reconciled DLQ" case in `WorkerSpec` with a route-error job and asserting the
DLQ depth. In `WireCompatSpec`, assert that the captured `preUpgradeRunJob` literal still decodes,
that re-encoding it produces the identical bytes, that its decoded `routeKind` is
`InferredLegacyRoute`, and that a job carrying an explicit route encodes with exactly one
additional key.

**Scheduler catch-up** — fails before. In `SchedulerSpec`, arm an agent on `* * * * *` at a fixed
instant, then invoke the fire action with a `TimerRow` whose `dueAt` is 24 hours in the past under
`SkipMissed`. Assert that exactly one run job is enqueued and that the newly armed timer's
`fireAt` is strictly greater than `now`. The fails-before counterpart runs the same scenario under
`FireAll` and observes the newly armed timer still in the past. Read the queue with the pgmq
helper `readRunJobs` the spec already has. Separately assert that a schedule fire whose
`enqueueScheduledRun` fails leaves the timer unfired — point the pool at a closed connection — and
that the failure produced a `scheduler.schedule.enqueue_failed` log line; capture the logger output
with `Shikigami.Log.newHandleLogger` over a temporary handle. Finally, assert that a `TimerRow`
carrying a payload with an unrecognized `kind` returns `Nothing` and logs
`scheduler.timer.unknown_kind`, and that an approval-timeout payload still reaches
`approvalTimeoutFireAction`.

**Kioku propagation** — fails before. The original wording here proposed driving the writes
against an unavailable store. That cannot work: `runKioku` and the workflow journal read the same
`connectionSettings`, so a store the kioku writes cannot reach is also one the journal cannot
reach, and `runAgentRunWorkflow` would fail at `loadJournal` before any step ran — proving nothing
about the writes. The refusal layer is what is drivable, and it is the layer that matters, because
a refusal is the case a retry cannot fix. In `AgentWorkflowSpec`, run an ordinary agent with a
`RunJob` carrying `delegationDepth = Just (-1)`; kioku's `validateLineage` refuses the session
open while the store stays healthy. Assert the run does not return `Completed (Right …)` but
`Completed (Left (PermanentAgentRunFailure detail))` whose detail names the refused write, and
that a replay answers the same way rather than opening a session on the second attempt. Before
this milestone the identical scenario returns a completed, successful run over a session that was
never opened. `agentJobOutcome`'s mapping of both arms — `Left _storeError -> RetryDefault` and
`PermanentAgentRunFailure -> Dead` — is already pinned by `WorkerSpec`'s outcome table.

The one explicitly best-effort write is not driven end to end. It runs only inside `failSession`
under `recordPolicy = Always`, after a session that kioku accepted, and no declaration-level input
makes just that memory write fail while the surrounding session writes succeed. It has a single
call site, it logs `agent.memory.best_effort_failed` on both failure layers, and it is the only
kioku result on this path that does not decide the run's outcome — that is what is verified by
reading it, and it is stated here rather than claimed as tested.

**Loud loading** — fails before. Call `loadAgentsLoud logger "../agents" False` against a captured
logger and assert the emitted JSON contains `agents.manifest.load_failed` with
`"path":"../agents/broken.dhall"`, that the summary says `"failed":1`, that the report retains an
`AgentLoadFailed` entry for it, and that `loadedAgents` excludes it. Call with strict `True` and
assert it raises `ExitFailure 1` after reporting every failure — `System.Exit.exitFailure` throws
a catchable `ExitCode`, so `try @ExitCode` proves the refusal in process and no subprocess is
needed. Before this plan the strict path is unreachable because nothing supplies the flag.

**Loud crons** — fails before. Build an `AgentDecl` with `trigger = Schedule { cron = "not a
cron" }`, run it through `Shikigami.Workers.Config.schedulerSchedules`, and assert only the
parseable agent is in the resulting map, that `scheduler.cron.invalid` names the offender, and
that under strict mode the call raises `ExitFailure 1` after reporting it. Today the agent is
dropped with nothing logged.

**Enqueue hardening** — fails before, except the queue-name case which is a regression guard.
`shikigami-core/test/Shikigami/EnqueueHardeningSpec.hs` asserts `parseQueueName
"shikigami_run_jobs"` is `Right` and that `runQueueName` renders back to that literal; that
`envelopeOccurredAt` returns `Nothing` for a bogus timestamp and that the job built from the
caller's clock lands within a second of `getCurrentTime` rather than in 1970; that
`addressedRunKey` agrees with itself across two calls for one logical event and disagrees across
agents and payloads; and that `nameBytes` separates two names differing above U+00FF while an
ASCII name still hashes to its ASCII bytes — the latter is what proves no id any checked-in
manifest produces has moved.

Removing the per-send `createQueue` has an observable consequence that is itself the proof: three
`SchedulerSpec` cases failed with `relation "pgmq.q_shikigami_run_jobs" does not exist` until they
called `ensureRunQueue` first, exactly as the two production startup paths now do.

**Operationally**, the scheduler check in Concrete Steps is the human-visible acceptance: stop the
scheduler for several minutes on a `* * * * *` agent, restart it, and observe one enqueued run
rather than one per missed minute.


## Idempotence and Recovery

All changes are code-only; there are no migrations. Re-running builds and tests is safe, and each
database-backed test gets a fresh database through `withShikigamiMigratedDatabase`.

The routing change is safe to deploy while jobs are in flight. A job enqueued by the old code has
no `routeKind` key, decodes to `InferredLegacyRoute`, and is handled by the same duck-typed
decision it would have received before, with a warning line naming it. A parked workflow whose
`ingest-job` step was journaled before the deploy replays identically, because the codec omits the
field when it holds the legacy default — the property `WireCompatSpec` pins. Once
`worker.job.route_inferred` stops appearing in production logs, the constructor and its branch can
be deleted in a follow-up; that deletion is not part of this plan.

The scheduler change is safe with timers armed. Each armed timer fires once and re-arms under the
new policy. On the first start after the upgrade, any pre-existing stale backlog collapses to a
single run rather than draining — that is the point — but the one stale tick already armed does
still fire, so expect exactly one catch-up run per scheduled agent. Rolling back re-arms from the
fired `dueAt` again and resumes the old behavior; no state is left behind that the old code cannot
read.

The loud-loading default stays lenient (`agents.strict = false`), so upgrading never turns a
tolerated broken manifest into a failed deploy without an explicit configuration change. The
catch-up default does change behavior on upgrade, deliberately and in the safe direction; setting
`scheduler.catch_up=fire_all` restores the old behavior without a rollback.

Enqueue-key changes affect only newly produced jobs; jobs already queued under old keys are
unaffected and still process. The UUIDv5 encoding change moves no id for any ASCII name, so
in-flight timers, outbox rows, and delegated child workflows keyed by ASCII agent names are
untouched; a non-ASCII agent name would get a new id, which is the collision this fixes, and any
in-flight timer for such a name should be drained before the deploy.

Each milestone leaves the tree building and the suite green, so a partially completed plan is a
safe stopping point.


## Portfolio Reconciliation (revised 2026-08-20)

Every plan this one hard-depended on has landed. Plan 17 delivered the retry/timeout/heartbeat
semantics and moved run-job acknowledgement onto `keiro-pgmq`'s `Job`/`JobOutcome`; plan 18
delivered `enqueueRunJobTx` and `ensureRunQueue` and the atomic inbox-to-queue boundary; plan 36
delivered the seven-package split and the single agent loader; plan 37 delivered the Settei
configuration surface; plan 47 and plan 53 delivered the current dependency cohort; plan 33
delivered this plan's own `AgentLoadReport` slice.

Consume those surfaces rather than recreating them. Do not construct a shibuya `AckDecision` for a
run job, do not add a second queue-initialization helper, do not add a second agent-directory
traversal, and do not read the process environment directly from scheduler or loader code — every
setting arrives through `AppConfig`.

Downstream, plan 30 renders `AgentLoadReport` in an operator `agents list` command, plan 33 has
already built enabled-agent selection on it, and plan 23 will persist it against meibo principals.
This plan reports and logs; it does not persist.

One correction to propagate upward when this plan lands: MasterPlan 3's note that strict mode must
expect two failing fixtures under `agents/` is wrong, because the traversal is not recursive and
never reaches `agents/detectors/schema.dhall`. There is exactly one expected failure,
`agents/broken.dhall`.


## Interfaces and Dependencies

Hard dependencies, all satisfied: plans 17, 18, 33, 36, 37, and 47. Catch-up and strict settings
are Settei values resolved into `AppConfig`; no scheduler or loader code reads the environment
directly.

Libraries and why. `aeson` supplies `fromJSON` for the route validation and the hand-written
`RunJob` codec. `keiro` supplies `Keiro.Timer` — `TimerRow`, `TimerRequest`, `scheduleTimerOnceTx`
— and `Keiro.Workflow.Sleep.runWorkflowTimerWorker`, whose fire action returns
`Maybe EventId` and treats `Nothing` as "not fired, leave it for requeue" (verified in keiro
`keiro/src/Keiro/Timer.hs:159-188` and `keiro/src/Keiro/Workflow/Sleep.hs:390-433`). `keiro-pgmq`
supplies `JobOutcome`, the typed `Job`, and the reconciled DLQ that a `RouteError` lands in.
`cron`, through `Shikigami.Trigger.Schedule`, supplies `nextDue`. `text` supplies
`Data.Text.Encoding.encodeUtf8` for the UUIDv5 fix, and `base` supplies `System.Exit.exitFailure`
for strict mode. `settei` supplies the configuration declaration. `dhall`, through
`Shikigami.Agent.Loader.loadAgent`, supplies manifest loading.

Signatures that must exist at the end, with full module paths:

```haskell
-- shikigami-core/src/Shikigami/Agent/RunJob.hs
data RunRouteKind = AgentWorkflowRoute | ConversationWorkflowRoute | InferredLegacyRoute
-- RunJob gains routeKind :: !RunRouteKind, with hand-written ToJSON/FromJSON that
-- omit the key for InferredLegacyRoute and restore it when the key is absent.

-- shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs
data Shikigami.Agent.RunJob.Worker.RunRoute
  = ConversationRoute !AddressedMessage | AgentRunRoute | RouteError !Text
Shikigami.Agent.RunJob.Worker.routeRunJob :: RunJob -> RunRoute
Shikigami.Agent.RunJob.Worker.routeErrorJobOutcome :: Text -> JobOutcome

-- shikigami-workers/src/Shikigami/Workers/Config.hs
-- WorkerEnv gains: catchUpPolicy :: !CatchUpPolicy, read through envCatchUpPolicy

-- shikigami-core/src/Shikigami/Agent/Workflow.hs
data Shikigami.Agent.Workflow.StepResult a = StepProduced !a | StepRefused !Text
-- The journaled value for open-session, record, complete, and fail-session.
-- StepProduced encodes as the bare value (ADR 0011); only StepRefused adds a key.

-- shikigami-core/src/Shikigami/Agent/Approval.hs
Shikigami.Agent.Approval.approvalTimeoutKind :: Text   -- newly exported

-- shikigami-core/src/Shikigami/Trigger/Schedule.hs
data Shikigami.Trigger.Schedule.CatchUpPolicy = SkipMissed | FireAll

-- shikigami-core/src/Shikigami/App/Config.hs
-- AppConfig gains: schedulerCatchUp :: !CatchUpPolicy   -- key scheduler.catch_up
-- AppConfig gains: agentsStrict     :: !Bool            -- key agents.strict

-- shikigami-workers/src/Shikigami/Trigger/Scheduler.hs
-- SchedulerEnv gains: catchUpPolicy :: !CatchUpPolicy, logger :: !Log.Logger
-- The fire actions take the instant keiro claimed the timer at, so the re-arm
-- cannot disagree with the claim (see the Decision Log).
Shikigami.Trigger.Scheduler.shikigamiTimerFallback ::
  (Store :> es, IOE :> es) => SchedulerEnv -> UTCTime -> TimerRow -> Eff es (Maybe EventId)
Shikigami.Trigger.Scheduler.scheduleFireAction ::
  (Store :> es, IOE :> es) => SchedulerEnv -> UTCTime -> TimerRow -> Eff es (Maybe EventId)
Shikigami.Trigger.Scheduler.timerPayloadKind :: Value -> Maybe Text

-- shikigami-core/src/Shikigami/Agent/Loader.hs
Shikigami.Agent.Loader.loadAgentsLoud :: Log.Logger -> FilePath -> Bool -> IO AgentLoadReport
Shikigami.Agent.Loader.enabledAgentsFromReport :: Log.Logger -> AgentLoadReport -> IO [AgentDecl]
-- loadAgentsIn is removed.

-- shikigami-workers/src/Shikigami/Workers/Config.hs
Shikigami.Workers.Config.schedulerSchedules ::
  Log.Logger -> Bool -> [AgentDecl] -> IO (Map Text CronSchedule)
-- WorkerEnv also gains: schedules :: !(Map Text CronSchedule), resolved once at boot.

-- shikigami-core/src/Shikigami/Id/Name.hs
Shikigami.Id.Name.nameBytes :: Text -> [Word8]   -- the UTF-8 bytes UUIDv5 hashes

-- shikigami-core/src/Shikigami/Trigger/Enqueue.hs
Shikigami.Trigger.Enqueue.envelopeOccurredAt :: ActivityEnvelope -> Maybe UTCTime
Shikigami.Trigger.Enqueue.runJobFromEnvelope :: UTCTime -> AgentDecl -> ActivityEnvelope -> RunJob
Shikigami.Trigger.Enqueue.addressedRunKey :: Text -> Value -> Text
Shikigami.Trigger.Enqueue.enqueueAddressedRunWithKey ::
  Pool -> Text -> RunRouteKind -> Value -> Text -> IO (Either UsageError MessageId)
-- enqueueAddressedRun is removed; enqueueRunJob no longer calls createQueue.
```

Documentation and durable-context updates that ship with the code:
`docs/operations/configuration.md` gains rows for `scheduler.catch_up` and `agents.strict`;
`config/shikigami.example.yaml` gains both keys; and
`docs/architecture/shikigami-domain-inventory.md:157-165` is corrected to describe nine `RunJob`
fields including `routeKind`, noting that the specification still inventories only the three it
refers to. Write `docs/adr/0012-*.md` recording the route discriminator and the rule that a job
without one keeps its historical behavior — the corpus is plain Markdown with sequential
`NNNN-kebab-slug.md` names and no OKF frontmatter, per `docs/adr/README.md`, and 0011 is the
highest allocated number today.


## Revision Notes

- 2026-07-22: Made plans 17 and 18 prerequisites, promoted loading to the canonical
  `AgentLoadReport` seam, and assigned plans 30, 33, and 23 as consumers. This removes
  the prior "whichever lands first" duplication across MasterPlans 3, 4, 6, and 7.
- 2026-07-22: Replaced trigger-kind inference with an explicit route discriminator,
  made truth-bearing Kioku failures propagate, moved settings to Settei, and added the
  old-job compatibility gate.
- 2026-08-20: Full refresh against the delivered tree. The plan's intent survived; most of its
  premises did not. Every file path was re-verified and corrected: the worker is
  `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs`, the scheduler is
  `shikigami-workers/src/Shikigami/Trigger/Scheduler.hs`, `RunJob` is
  `shikigami-core/src/Shikigami/Agent/RunJob.hs` (the previously named
  `shikigami-api/src/Shikigami/Api/RunJob.hs` never existed), and `shikigami-cli` is gone. Plan
  17's landing replaced the shibuya `AckDecision` vocabulary this plan was written against with
  `keiro-pgmq`'s `JobOutcome`, so `RouteError` now dead-letters through the handler's existing
  `deadOutcome`. Two claims were found to be wrong and are corrected rather than carried forward:
  the approval-timeout fall-through does not misfire, because both timer payloads are
  kind-guarded, so Milestone 2's dispatch change is re-scoped to explicitness and diagnostics; and
  `SkipMissed` needs no bounded loop, because `nextDue` already returns the first strictly-future
  tick. Three constraints that did not exist at authoring time are now honored: `RunJob` is
  journaled and its bytes are pinned by `WireCompatSpec`, so the new field follows ADR 0011's
  omit-when-default codec and gains an `InferredLegacyRoute` compatibility constructor;
  `CatchUpPolicy` must live in `shikigami-core` because `AppConfig` carries it and core cannot
  depend on workers; and metrics do not exist yet, so Milestone 3 logs only. `CoalesceToLatest`
  was dropped as indistinguishable from `SkipMissed` at minute granularity. Milestone 4 grew the
  two follow-through items the `createQueue` removal exposes (`ensureRunQueue` in the scheduler
  and in `enqueue-run`), three more UUIDv5 sites than the plan listed, and the loader's move onto
  `Shikigami.Log`. Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective
  were all brought in line with what has actually landed, including the report slice plan 33
  delivered.
