---
id: 7
slug: agent-runs-as-durable-keiro-workflows
title: "Agent runs as durable keiro workflows"
kind: exec-plan
created_at: 2026-06-27T16:23:56Z
intention: "intention_01kw4y6kpnetmsfz4nwzkpnewc"
---

# Agent runs as durable keiro workflows

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, when `shinzui/shikigami` runs an agent, the run executes start-to-finish in one
shot and cannot pause. If the process crashes halfway through, the whole run re-executes
from the beginning, repeating side effects that already happened. And there is no way for a
run to stop, ask a human "may I do this?", and continue later when the answer arrives —
agents are batch jobs, not supervised peers.

This plan re-platforms the shikigami agent run onto a **durable workflow** provided by the
`shinzui/keiro` runtime. A durable workflow is an ordinary program whose individual steps
are *journaled* (recorded to a database) so that, after a crash, the run resumes at the
first step that did not finish rather than re-running completed steps. The same machinery
lets a run *suspend* — park itself, persist its position, and wake up later when an external
event arrives or a timer fires.

After this change, a person can observe two new behaviors that are impossible today:

1. **Crash recovery mid-run.** Start an agent run, kill the worker process while the run is
   between two steps, restart the worker, and watch the run continue from where it stopped —
   the already-completed steps (for example, "session opened", "prior memory recalled") are
   not repeated, and their external effects do not happen twice.

2. **Park-and-resume on approval.** An agent run reaches a point where it must ask for
   approval before acting. It calls a new combinator, `awaitApproval`, which suspends the
   run (the worker is now free to do other work), optionally arms a deadline timer, and
   records that the run is waiting. When a human answers — the answer arrives as an event —
   the run resumes exactly where it parked and proceeds (or, if the deadline passes first,
   resumes with a "timed out" decision).

This re-platforming is the **keystone**: three sibling shikigami plans (a conversational
loop, multi-agent delegation, and a timer-driven scheduler with tracing) all build directly
on the durable-workflow foundation laid here. Externally, everything else is preserved: the
three ways a run is triggered (a schedule, a data stream, an addressed event), and the four
places a run sends its output (the `kawa` digest service, the `kizashi` signal service, the
`rei` action service, and the `danwa` conversation service) behave exactly as before. The
only new externally-visible capability is suspend/resume.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M1 (spike)**: Prove a trivial keiro workflow runs inside shikigami's process using
      the kiroku `Store` handle already inside the kioku `AppEnv`, and that a crash between
      two steps resumes without re-running the first step. Throwaway code under
      `shikigami-core/test/`. Completed 2026-06-27T17:58:29Z; validation command:
      `nix develop -c cabal test shikigami-core-test --test-options='-p Spike'`.
- [x] **M1**: Confirm keiro workflow tables exist after `just migrate` (no migration wiring
      needed — they are applied transitively through kioku); document the finding.
      Completed 2026-06-27T17:58:29Z; `just create-database` reported zero pending
      migrations in the dev database, and `\dt kiroku.keiro_*` showed the keiro workflow
      and outbox tables in the `kiroku` schema.
- [x] **M2**: Add `shikigami-core/src/Shikigami/Agent/Workflow.hs` expressing the run
      lifecycle (ingest job → open session → recall → run behavior → dispatch sinks → record
      learning → complete) as journaled steps; entry point `runAgentRunWorkflow`.
      Completed 2026-06-27T18:18:01Z.
- [x] **M2**: Change `Shikigami/Worker.hs` to drive the run through `runAgentRunWorkflow`
      instead of calling `runAgentWithMemory` directly; map `Completed`/`Suspended` to ack.
      Completed 2026-06-27T18:18:01Z.
- [x] **M2**: Add a resume worker (keiro `runWorkflowResumeWorker` with a one-entry
      registry) as a second component in the worker process. Completed 2026-06-27T18:18:01Z.
- [x] **M2**: Implement the transactional sink outbox path for `dispatch-sinks` and run an
      outbox publisher loop in the worker process. Completed 2026-06-27T18:18:01Z.
- [ ] **M2**: Test — existing run behavior unchanged; a multi-step run killed mid-flight
      resumes without repeating completed steps. Current coverage: `AgentWorkflow` verifies a
      completed workflow replays lifecycle steps for the same run id, and the full
      `shikigami-core-test` suite reports `All 13 tests passed`; remaining coverage is an
      explicit fault-injection crash-resume test for an unfinished run.
- [ ] **M3**: Add `shikigami-core/src/Shikigami/Agent/Approval.hs`: the `awaitApproval` /
      `awaitInput` combinator built on keiro `awakeableNamed`; a policy hook
      `requiresApproval` (static stub now, `en` later); a park-state hook (log stub now,
      kioku `Awaiting` later); the ask posted via the existing kizashi/danwa sink clients.
- [ ] **M3**: Wire the gate into the workflow before sink dispatch; expose
      `resolveApproval` so an inbound answer event resumes the run.
- [ ] **M3**: Test — a run that requires approval parks (workflow `Suspended`), and
      `signalAwakeable` resumes it to completion.
- [ ] **M4**: Add deadline support: arm a keiro timer when `awaitApproval` is given a
      deadline; run keiro's `runWorkflowTimerWorker` in the worker process; on fire the
      timer signals the awakeable with a `TimedOut` decision.
- [ ] **M4**: Test — a parked run with a short deadline resumes with `TimedOut` when no
      answer arrives.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (2026-06-27): The plan's assumption that `shikigami-core/test/` already had a
  database/AppEnv helper was stale. The current suite only had `shikigami-core/test/Main.hs`.
  The M1 spike therefore uses the existing `shikigami-migrations:test-support` public
  sublibrary, `withShikigamiMigratedDatabase`, then opens a `KirokuStore` with
  `withStore (defaultConnectionSettings connStr)` and builds a `Kioku.App.AppEnv` around
  that store. Evidence: `rg --files shikigami-core/test` returned only
  `shikigami-core/test/Main.hs` before the spike module was added.

- Discovery (2026-06-27): The keiro tables exist after shikigami migrations, but under the
  `kiroku` schema rather than as unqualified `public` relations. Evidence:
  `nix develop -c psql -h "$PGHOST" -d "$PGDATABASE" -c "\dt keiro_*"` returned `Did not
  find any relation named "keiro_*"`, while `\dt kiroku.keiro_*` listed
  `keiro_awakeables`, `keiro_timers`, `keiro_workflow_children`,
  `keiro_workflow_steps`, `keiro_workflows`, and `keiro_outbox`.

- Discovery (2026-06-27): The current test runner is Tasty, whose filter option is
  `-p/--pattern`, not `-m`. Evidence: `cabal test shikigami-core-test
  --test-options='-m Spike'` built the test binary but failed with `Invalid option '-m'`;
  `cabal test shikigami-core-test --test-options='-p Spike'` ran the single spike test and
  passed.

- Discovery (2026-06-27): Synchronous sink dispatch inside a journaled `step` cannot
  preserve the old retry semantics for transient sink failures. If the step records
  `[SinkResult]` containing a `Failed` outcome and the worker retries the pgmq message, the
  workflow replay returns the recorded failure without re-running the sink POST, so the
  worker can loop on the same failure forever or, if it ignores the failure, acknowledge a
  sink that was never delivered. This is concrete evidence that the Decision Log's
  transactional outbox requirement is not optional for M2. The implementation responded by
  replacing the synchronous `dispatch-sinks` step with a specialized transactional step that
  appends `StepRecorded "dispatch-sinks"` and enqueues `SinkIntent` outbox rows together.


## Decision Log

Record every decision made while working on the plan.

- Decision (implementation, 2026-06-27): New records introduced by this plan follow the
  repository record convention from `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/record-patterns.md`:
  no field prefixes, strict fields, and explicit deriving strategies. `AgentRunDeps` therefore uses
  `appEnv`, `behaviorEnv`, `agents`, `kizashi`, and `kawa`, not the earlier plan sketch's
  `ard*` field names.
  Rationale: prefixed record fields conflict with the shared Haskell convention and make later
  generic-lens `#field` access inconsistent. The plan and implementation were corrected when this was
  noticed during M2.
  Date: 2026-06-27

- Decision (implementation, 2026-06-27): `dispatch-sinks` is implemented as a specialized
  transactional workflow step rather than keiro's generic `step` helper. It uses
  `currentWorkflow`, `currentRunGeneration`, and `prepareJournalAppend` to prepare the
  `StepRecorded` journal insert, then runs that transaction together with `enqueueOutboxTx`
  for each allowed sink intent.
  Rationale: keiro's generic `step` helper appends the journal entry in its own internal
  transaction after the action returns, so an action that merely calls `enqueueOutboxTx`
  cannot guarantee "journal step and outbox rows commit together." The specialized step keeps
  the plan's transactional outbox guarantee while still replaying from the recorded
  `dispatch-sinks` result on later workflow runs.
  Date: 2026-06-27

- Decision (cross-plan coherence review, 2026-06-27, resolving audit item **C3**): Dispatch sinks via a
  **transactional outbox** (Option 3) — the `dispatch-sinks` step `enqueueOutboxTx`s a sink-intent row
  into `kiroku.keiro_outbox` in the same transaction as the journal step (exactly-once, deterministic
  `message_id` from `(WorkflowId, sinkIndex)`), and a separate **outbox publisher** worker
  (`publishClaimedOutbox` with a shikigami HTTP publish function) delivers it at-least-once, idempotent at
  the destination. Sinks are **not** POSTed synchronously inside the step, and **not** dispatched outside
  the workflow after `Completed`.
  Rationale: The team is preparing these projects for `kikan` in production, where durable, decoupled,
  exactly-once-enqueued delivery matters more than proof-slice simplicity. The synchronous in-step POST
  (Option 2) risks at-least-once double-POST and couples run latency to sink-endpoint health; dispatch
  after `Completed` (Option 1) cannot express the mid-run sinks that flows (plan 11), the danwa loop
  (plan 8), and delegation (plan 9) require, and loses sinks on a post-`Completed` crash. The keiro outbox
  (`kiroku.keiro_outbox`, already in the composed migrations) gives all three plans one durable,
  production-grade sink path. Chosen by the user on 2026-06-27.
  Date: 2026-06-27

- Decision (cross-plan coherence review, 2026-06-27, resolving audit item **C2**): Expose a **generic
  `WorkflowId`-keyed input channel** — `awaitInput :: StepName -> Eff es a` and
  `deliverInput :: WorkflowId -> StepName -> a -> Eff es Bool` — as the base durable park/resume
  primitive, with `awaitApproval`/`resolveApproval` recast as its typed approval specialisation.
  Rationale: Plan 8 (danwa conversational loop) needs to resume a parked run knowing only its run id
  (the conversation id = workflow id), not the opaque `AwakeableId` that the approval-shaped `awaitInput`
  required. A generic channel keyed by `(WorkflowId, StepName)` serves plan 8, plan 11's free-form
  waits, and keeps the approval flow as a thin layer on top. Chosen by the user on 2026-06-27.
  Date: 2026-06-27

- Decision (cross-plan coherence review, 2026-06-27): The single `runWorkflowTimerWorker` this plan
  runs in M4 (with a shikigami fallback fire action for `awaitApproval` deadline timers) is the **one
  and only** timer worker in the worker process; sibling plan 10's scheduled-agent timers
  (`docs/plans/10-timer-driven-schedules-mid-run-resume-and-run-tracing.md`) are routed by the **same**
  fallback, not a second worker loop. The agreed shape is one
  `shikigamiTimerFallback :: TimerRow -> Eff es (Maybe EventId)` that dispatches by the payload `"kind"`
  discriminator — `shikigami.approval-timeout` → this plan's approval fire action, `shikigami.schedule`
  → plan 10's `scheduleFireAction`, else `Nothing` — under one `runWorkflowTimerWorker`. This plan owns
  the entrypoint and the approval branch; plan 10 contributes the schedule branch.
  Rationale: The audit of plans 7–11 found plan 10 implied a separate scheduler timer-worker loop, which
  would compete with this plan's worker for the same `keiro_timers` rows. Recording the shared entrypoint
  here keeps the two plans coherent.
  Date: 2026-06-27

- Decision: Re-platform the run onto a **keiro workflow** rather than build an ad-hoc
  suspend/resume mechanism in shikigami.
  Rationale: `shinzui/keiro` already provides journaled steps, suspension
  (`awaitStep`), external-signal promises (`awakeableNamed` / `signalAwakeable`), durable
  timers (`sleepNamed`, the timer worker), child workflows, and a resume worker
  (`runWorkflowResumeWorker`). The gap analysis names this the keystone: "Nothing requires
  new durable infrastructure; it is all abstractions over the keiro runtime." Building our
  own would duplicate proven, tested machinery and would not be reused by the sibling plans.
  Date: 2026-06-27

- Decision: Run the keiro workflow on the **same kiroku `Store` handle that kioku already
  uses**, taken straight from the kioku `AppEnv` (`store :: KirokuStore`).
  Rationale: keiro's `Workflow` effect requires `Store :> es` where `Store` is
  `Kiroku.Store.Effect.Store` — the very effect kioku's `runAppIO` interprets with
  `runStorePool (store env)`. The workflow journal therefore lives in the same Postgres
  event store as the agent's sessions and memories. No second connection pool, no new
  infrastructure. The workflow body's effect row is exactly kioku's `AppEffects`
  (`'[Store, Error StoreError, Tracing, IOE]`) plus `Workflow`, so the existing kioku
  session/recall/record operations can be called *directly inside* `step` bodies.
  Date: 2026-06-27

- Decision: The `awaitApproval` seam lives in shikigami as a **workflow-step combinator**;
  the durable park *state* and the approval *channel* are explicitly out of scope here.
  Rationale: the gap analysis splits this cleanly. The park *state* (an `Awaiting` session
  vertex plus the continuation) is an additive event on kioku's event-sourced session
  machine — owned by the kioku repo plan "Awaiting session state for durable park-and-resume".
  The *ask itself* rides existing rails — a `kizashi` signal or a `danwa` question — already
  present as sink clients in shikigami. The *policy* deciding when approval is required is
  owned by the `en` repo plan "Per-action authorization...". This plan owns only the
  combinator and its integration seam, and stubs the three dependencies behind small hooks
  so it is independently shippable and testable.
  Date: 2026-06-27

- Decision: Model the deadline as a **timer that signals the same awakeable**, not as a race
  between two suspension points.
  Rationale: keiro's suspension primitive `awaitStep` awaits one named step. Rather than
  introduce a select/race primitive, the deadline is just a second producer of the same
  answer: a keiro timer whose fire action calls `signalAwakeable aid TimedOut`. There is a
  single await point (the awakeable); whichever producer (human answer or timer) journals
  first wins, and the other becomes a no-op (`signalAwakeable` is idempotent and returns
  `False` once the promise is already completed).
  Date: 2026-06-27

- Decision: Use the run's **idempotency key as the workflow id**, and journal the trigger
  payload as the first step.
  Rationale: keiro identifies a workflow by `(WorkflowName, WorkflowId)` and the resume
  worker rebuilds a workflow body from its id alone via a registry. The existing `RunJob`
  already carries `idempotencyKey :: Text`; using it as the `WorkflowId` makes the same
  trigger map to the same workflow (dedupe + resumability). The full `RunJob` is captured by
  journaling it as the first `step "ingest-job"`, so a resume — which has only the id — reads
  the job back from the journal and is fully self-contained.
  Date: 2026-06-27

- Decision: Keep `runAgentWithMemory` as a thin internal helper but stop calling it from the
  worker; the workflow becomes the single run path.
  Rationale: the lifecycle logic (session/recall/record/complete) is reused verbatim inside
  the workflow's step bodies. A parallel path during migration (M1 spike, then M2) keeps
  tests green while the workflow path is proven, after which the direct call is removed.
  Date: 2026-06-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- M1 outcome (2026-06-27): The spike proves keiro workflows can run inside shikigami's test
  process on the same kiroku store handle shape that `Kioku.App.AppEnv` carries. The first
  run journals `step "one"` and then throws a simulated crash; the second run with the same
  `WorkflowName "shikigami.spike"` and `WorkflowId "spike-replay"` completes with
  `Completed "two"` while the `IORef` counter for step one remains `1`. This validates the
  replay assumption needed before M2 moves the production agent lifecycle into a workflow.
  M1 also verified that no migration wiring is required, with the qualification that the
  keiro relations are in schema `kiroku`. The full core test suite was run after the spike:
  `nix develop -c cabal test shikigami-core-test` reported `All 12 tests passed`.


## Context and Orientation

This section assumes no prior knowledge of this repository or its dependencies. Read it
fully before editing anything.

### What shikigami is

`shinzui/shikigami` (working tree at `/Users/shinzui/Keikaku/bokuno/shikigami`) is a
declarative agent runtime written in Haskell (GHC 9.12.4). An *agent* is declared in a Dhall
configuration file (an `AgentDecl`) that says how it is triggered, what behavior it runs, and
where it sends output. The repository is a multi-package cabal project; `cabal.project` lists
the packages:

```text
packages:
  shikigami-api       -- client-safe wire types (AgentDecl, RunJob, Activity)
  shikigami-core      -- the runtime: triggers, run lifecycle, behaviors, sinks, worker
  shikigami-cli       -- command-line entry points
  shikigami-migrations-- database schema (codd migrations)
```

The work in this plan is almost entirely in **`shikigami-core`**.

### The current run lifecycle (what we are re-platforming)

A *run* is one execution of one agent against one trigger payload. Its lifecycle lives in
`/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-core/src/Shikigami/Agent/Run.hs`. The
entry point is:

```haskell
runAgentWithMemory :: AppEnv -> BehaviorEnv -> AgentDecl -> Value -> IO (Either Text AgentRunResult)
```

It performs, in order:

1. **Open a kioku session.** `kioku` (`shinzui/kioku`) is the event-sourced session and
   memory engine. A *session* is a durable record that the agent did some work; opening one
   calls `Session.start` with a `StartSessionData`.
2. **Recall prior learnings.** `recallPriorLearnings` queries kioku for memories scoped to
   this agent (hybrid full-text + vector search, falling back to scope listing).
3. **Run the behavior.** `runBehavior` (see below) executes the agent's behavior and returns
   a JSON `Value`.
4. **On error**, fail the session (`Session.failSession`) and return `Left`.
5. **On success**, record the result as a durable memory (`Memory.record`, type
   `MemoryPattern`, scoped to the agent), then complete the session (`Session.complete`),
   and return `Right AgentRunResult{...}`.

The result type is:

```haskell
data AgentRunResult = AgentRunResult
  { runSessionId   :: !SessionId
  , recalledPrior  :: ![MemoryRecord]
  , behaviorOutput :: !Value
  , recordedMemId  :: !(Maybe MemoryId)
  }
```

`runAgentWithMemory` runs in `IO`; internally it uses kioku's `runAppIO :: AppEnv -> Eff
AppEffects a -> IO (Either StoreError a)`, where (see
`/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/App.hs`):

```haskell
data AppEnv = AppEnv
  { store   :: !KirokuStore   -- the kiroku event-store connection handle
  , tracer  :: !Tracer
  , metrics :: !(Maybe KeiroMetrics)
  }

type AppEffects = '[Store, Error StoreError, Tracing, IOE]

runAppIO :: AppEnv -> Eff AppEffects a -> IO (Either StoreError a)
runAppIO env =
  runEff . runTracing (tracer env) . runErrorNoCallStack . runStorePool (store env)
```

The single most important fact for this plan: **`AppEnv` already carries `store ::
KirokuStore`, and that is exactly the `Store` effect keiro workflows require.** We do not add
any new database connection; we reuse this one.

### How the behavior is executed

`/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-core/src/Shikigami/Behavior/Run.hs`:

```haskell
runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError Value)
```

It dispatches on the agent's declared behavior: a typed program (`ShikumiProgram`, run via
the `handan` runtime), a `Skill` (a Markdown skill run via the `baikai` LLM client — see
`Shikigami/Behavior/Skill.hs`), or `Deterministic` (a rule; currently unsupported). For this
plan, `runBehavior` is treated as one opaque step; decomposing the skill loop into finer
journaled steps belongs to the conversational-loop sibling plan, not here.

### How a run is triggered and dispatched

A trigger produces a `RunJob` and enqueues it on a Postgres-backed queue. The job type and
enqueue function live in
`/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-core/src/Shikigami/Trigger/Enqueue.hs`:

```haskell
data RunJob = RunJob
  { agentName      :: !Text
  , triggerKind    :: !TriggerKind          -- schedule | stream | event
  , occurredAt     :: !UTCTime
  , triggerPayload :: !Value
  , idempotencyKey :: !Text
  }

enqueueRunJob :: Pool -> RunJob -> IO (Either UsageError MessageId)
```

The queue is **pgmq** ("Postgres Message Queue"), queue name `shikigami_run_jobs`. A worker
drains it. *shibuya* (`shinzui/shibuya`) is the small library that provides the
queue-processing loop. The worker is
`/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-core/src/Shikigami/Worker.hs`:

```haskell
data WorkerEnv = WorkerEnv
  { workerPool        :: !Pool          -- pgmq connection pool
  , workerAppEnv      :: !AppEnv        -- kioku app env (carries the Store handle)
  , workerAgents      :: ![AgentDecl]
  , workerBehaviorEnv :: !BehaviorEnv
  , workerKizashi     :: !KizashiConfig
  , workerKawa        :: !KawaConfig
  }

runWorker :: WorkerEnv -> IO ()
```

`runWorker` builds a pgmq adapter and runs shibuya's processor under `runTracingNoop` (a
no-op tracer; wiring real tracing is the scheduler/tracing sibling plan, not this one). For
each job it decodes a `RunJob`, looks up the `AgentDecl` by name, calls `runAgentWithMemory`,
dispatches sinks, and maps outcomes to an ack decision (`AckOk`, `AckRetry`, or
`AckDeadLetter`).

### How output is dispatched (sinks) and authorized

`/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-core/src/Shikigami/Sink.hs`:

```haskell
dispatch :: SinkContext -> Sink -> Value -> IO SinkResult
```

For each declared sink it first calls `checkGrant` (the static per-agent authorization gate
in `Shikigami/Sink/Permission.hs`), then routes to the kawa, kizashi, rei, or danwa client.
A *sink* is a destination for a run's output. `kizashi` and `danwa` are the two we reuse in
this plan as the channel for an approval ask. This per-sink authorization gate is *not* the
approval policy of this plan; per-action authorization via `en` is a separate plan (gap 7).

### What keiro gives us (the durable-workflow runtime)

`shinzui/keiro` (working tree at `/Users/shinzui/Keikaku/bokuno/keiro`, pinned in
`cabal.project`) is described as "the event-sourcing framework and workflow engine". Its
workflow surface is the module **`Keiro.Workflow`**
(`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow.hs`). The terms below are the
exact vocabulary this plan uses; learn them.

- **Workflow effect.** `Workflow` is an `effectful` effect. You write a workflow as an
  ordinary `Eff (Workflow : es) a` computation and run it with `runWorkflow`:

  ```haskell
  runWorkflow ::
      (IOE :> es, Store :> es) =>
      WorkflowName ->
      WorkflowId ->
      Eff (Workflow : es) a ->
      Eff es (WorkflowOutcome a)
  ```

  `WorkflowName` and `WorkflowId` are `newtype`s over `Text`. `WorkflowOutcome a` is
  `Completed a | Suspended` — a workflow either finishes with a value or parks.

- **Journaled step.** The replay-safety primitive:

  ```haskell
  step :: (Workflow :> es, ToJSON a, FromJSON a) => StepName -> Eff es a -> Eff es a
  ```

  The first time control reaches `step name action`, it runs `action`, JSON-serializes the
  result, and appends a `StepRecorded` entry to the journal (a kiroku stream named
  `wf:<name>-<id>`). On a later replay after a crash, `step name action` finds the recorded
  result by `name` and returns it **without re-running `action`**. Steps are identified by
  their string name, not by source position. Step bodies that touch external systems must be
  idempotent because the side effect is at-least-once across a crash that happens after the
  effect but before the journal commit.

- **Suspension primitive.**

  ```haskell
  awaitStep :: (Workflow :> es, FromJSON a) => StepName -> Eff es () -> Eff es a
  ```

  If a result for `name` is already journaled, return it. Otherwise run the idempotent
  *arming* action once and **suspend the run** (the runtime throws an internal sentinel that
  `runWorkflow` catches and turns into `Suspended`). On every resume the arming action runs
  again until the result is journaled, so it must be idempotent.

- **External-signal promise (an "awakeable").** Module `Keiro.Workflow.Awakeable`:

  ```haskell
  awakeableNamed ::
      (Workflow :> es, Store :> es, IOE :> es, FromJSON a) =>
      StepName ->
      Eff es (AwakeableId, Eff es a)

  signalAwakeable :: (IOE :> es, Store :> es, ToJSON r) => AwakeableId -> r -> Eff es Bool
  cancelAwakeable :: (Store :> es) => AwakeableId -> Eff es Bool
  ```

  `awakeableNamed` returns an opaque `AwakeableId` (a UUID you hand to the outside world) and
  an await action that suspends the workflow until someone calls `signalAwakeable thatId
  result`. `signalAwakeable` is idempotent and returns `True` only on the transition from
  pending to completed. This is exactly how an approval answer wakes a parked run.

- **Durable timer.** Module `Keiro.Workflow.Sleep`:

  ```haskell
  sleepNamed :: (Workflow :> es, Store :> es, IOE :> es) => StepName -> NominalDiffTime -> Eff es ()
  ```

  and a timer worker that fires due timers:

  ```haskell
  runWorkflowTimerWorker ::
      (IOE :> es, Store :> es) =>
      Maybe KeiroMetrics ->
      UTCTime ->
      (TimerRow -> Eff es (Maybe EventId)) ->   -- fallback fire action for non-sleep timers
      Eff es (Maybe TimerRow)
  ```

  The fallback fire action is the seam we use to make a deadline timer call
  `signalAwakeable`.

- **Child workflow.** Module `Keiro.Workflow.Child` (`spawnChild`, `awaitChild`). Not used in
  this plan; it is the foundation for the delegation sibling plan.

- **Resume worker.** Module `Keiro.Workflow.Resume`. A workflow that suspended is woken by a
  background worker that rebuilds the body from a registry:

  ```haskell
  data WorkflowDef es = forall a. ToJSON a => WorkflowDef { runDef :: WorkflowId -> Eff (Workflow : es) a }
  type WorkflowRegistry es = Map WorkflowName (WorkflowDef es)

  resumeWorkflowsOnce :: (IOE :> es, Store :> es) => WorkflowRegistry es -> WorkflowResumeOptions -> UTCTime -> Eff es ResumeSummary
  runWorkflowResumeWorker :: (IOE :> es, Store :> es) => WorkflowRegistry es -> Eff es ()
  ```

  The registry maps a workflow name to a function that reconstructs the body given only the
  id. Because the resume worker has only the id, the body must read everything it needs from
  the journal — which is why we journal the `RunJob` as the first step.

A complete, real example to imitate is
`/Users/shinzui/Keikaku/bokuno/keiro/jitsurei/src/Jitsurei/DurableWorkflow.hs`
(an order-fulfillment workflow using `step`, `sleepNamed`, `awakeableNamed`, `spawnChild`,
`awaitChild`, and a `WorkflowRegistry`). Read it before writing M1.

### Database: the keiro tables already exist in shikigami

keiro's workflow tables are `keiro_workflow_steps` (the step index used on replay),
`keiro_workflows` (per-instance lifecycle/lease row), `keiro_timers`, `keiro_awakeables`,
`keiro_workflow_children`, and `kiroku.keiro_outbox` (the sink-dispatch outbox queue, migration
`keiro-migrations/sql-migrations/2026-05-17-01-00-00-keiro-outbox.sql`, with a unique
`(source, message_id)` index for exactly-once enqueue and `status`/`next_attempt_at` for retry).
**These are already created by shikigami's migrations**, because
the migration set composes transitively:
`/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-migrations/src/Shikigami/Migrations.hs`
defines `shikigamiMigrations = kiokuMigrations <> shikigamiOwnMigrations`, and
`/Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations/src/Kioku/Migrations.hs` defines
`kiokuMigrations = kirokuMigrations <> keiroFrameworkMigrations <> kiokuOwnMigrations`.
`keiroFrameworkMigrations`
(`/Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations/src/Keiro/Migrations.hs`) embeds the
`*.sql` files under `keiro-migrations/sql-migrations/` including
`...-keiro-workflow-steps.sql`, `...-keiro-awakeables.sql`,
`...-keiro-workflow-children.sql`, `...-keiro-workflows-instances.sql`, and the timer files.
**Therefore M1 needs no migration wiring** — only a verification that the tables are present
after `just migrate`. The migrate `Justfile` recipe is reproduced in Concrete Steps.

### Build and test commands

From `/Users/shinzui/Keikaku/bokuno/shikigami`:

```bash
nix develop                 # enter the dev shell (GHC 9.12.4, postgres, just, librdkafka)
cabal build all             # build every package
cabal build shikigami-core  # build just the runtime package
cabal test shikigami-core-test   # run the core test suite
just create-database        # create + migrate the dev database (idempotent)
just migrate                # apply migrations only (idempotent)
```

The dev shell (see `flake.nix`) starts a Unix-socket PostgreSQL under `./db` and sets
`PGHOST`, `PGDATABASE=shikigami`. The test suite brings up an ephemeral Postgres via the
`ephemeral-pg` dependency pinned in `cabal.project`, so tests do not require a running
database when run under `nix develop`.


## Plan of Work

The work is four milestones. Each is independently verifiable. M1 is a throwaway spike that
de-risks the keiro integration; M2 makes the run a durable workflow with crash recovery; M3
adds the `awaitApproval` combinator and park/resume on an answer event; M4 adds the deadline
timer. After M2 the system is behavior-preserving plus crash-resumable; M3 and M4 add the new
suspend/resume capability.

### Milestone 1 — Spike: a keiro workflow inside shikigami's process

**Scope.** Prove, with the smallest possible code, that (a) a keiro workflow runs using the
kiroku `Store` handle already inside shikigami's `AppEnv`, and (b) a crash between two steps
resumes without re-running the first step. Also confirm the keiro tables exist after migrate.

**What will exist at the end.** A throwaway test module
`shikigami-core/test/Shikigami/SpikeWorkflowSpec.hs` (added to the `shikigami-core-test`
suite's `other-modules`) containing a two-step workflow and a test that simulates a crash by
running the workflow twice with a shared mutable counter, asserting the first step's body
runs exactly once. Plus a Progress note recording that `keiro_workflow_steps` etc. are
present after `just migrate`.

**Commands.** `just create-database`; then `cabal test shikigami-core-test
--test-options='-p Spike'`.

**Acceptance.** The spike test passes: a side effect inside `step "one"` happens on the first
run, the run "crashes" (we throw after step one on the first pass), and the second run replays
step one from the journal (counter unchanged) and completes step two. This proves the Store
wiring and replay semantics before we touch production code.

This milestone is explicitly removable once M2 lands; it exists to fail fast if the
integration assumptions are wrong.

### Milestone 2 — The agent run is a durable keiro workflow

**Scope.** Express the existing run lifecycle as a journaled keiro workflow, drive it from the
worker, and add a resume worker so crashed runs continue. Behavior is otherwise unchanged.

**What will exist at the end.** A new module
`/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-core/src/Shikigami/Agent/Workflow.hs`
exporting:

```haskell
agentRunWorkflowName :: WorkflowName        -- WorkflowName "shikigami.agent-run"

-- | The run lifecycle as a workflow body. On the first run, mjob = Just the RunJob; on a
-- resume, mjob = Nothing and the job is read back from the journal's "ingest-job" step.
agentRunWorkflow ::
  AgentRunDeps ->
  Maybe RunJob ->
  Eff (Workflow : AppEffects) (Either Text AgentRunResult)

-- | Top-level: run one job to its first stopping point (completion or suspension).
runAgentRunWorkflow ::
  AgentRunDeps -> RunJob -> IO (Either StoreError (WorkflowOutcome (Either Text AgentRunResult)))

-- | The registry entry the resume worker needs.
agentRunRegistry :: AgentRunDeps -> WorkflowRegistry AppEffects
```

where `AgentRunDeps` bundles what the steps need (the `AppEnv`, the `BehaviorEnv`, the list of
`AgentDecl`s for name lookup, and the sink config). The workflow body performs the same
sequence as `runAgentWithMemory`, but each phase is a `step`:

```haskell
agentRunWorkflow deps mjob = do
  job   <- step (StepName "ingest-job") (ingest mjob)        -- journal the RunJob
  decl  <- step (StepName "lookup-agent") (lookupAgent deps job)
  sid   <- step (StepName "open-session") (openSession deps decl job)
  prior <- step (StepName "recall")        (recall deps decl)
  out   <- step (StepName "run-behavior")  (runBehaviorStep deps decl job)
  -- (M3 inserts the approval gate here, before sink dispatch)
  _     <- step (StepName "dispatch-sinks")(dispatchSinks deps decl out)
  mem   <- step (StepName "record")        (recordLearning deps decl sid out)
  _     <- step (StepName "complete")      (completeSession deps sid)
  pure (Right (AgentRunResult sid prior out mem))
```

The step bodies are the same operations `runAgentWithMemory` performs today, lifted into the
workflow's effect row (`Workflow : AppEffects`). Because `AppEffects` already provides
`Store`, `Error StoreError`, `Tracing`, and `IOE`, the kioku `Session`/`Recall`/`Memory`
calls run directly; the `IO`-typed `runBehavior` and sink `dispatch` calls are wrapped with
`liftIO`. Each step's result type must have `ToJSON`/`FromJSON` (a `SessionId`, a
`[MemoryRecord]`, a JSON `Value`, a `Maybe MemoryId` — all already JSON-serializable, or made
so with small newtype wrappers if needed).

`runAgentRunWorkflow` builds the effect stack mirroring `runAppIO` and runs the body through
`runWorkflow`, using the job's `idempotencyKey` as the `WorkflowId`:

```haskell
runAgentRunWorkflow deps job =
  let env = appEnv deps
   in runEff
        . runTracing (tracer env)
        . runErrorNoCallStack @StoreError
        . runStorePool (store env)
        $ runWorkflow agentRunWorkflowName (WorkflowId (idempotencyKey job))
                      (agentRunWorkflow deps (Just job))
```

`/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-core/src/Shikigami/Worker.hs` changes so
`runOneAgent` calls `runAgentRunWorkflow` instead of `runAgentWithMemory` + manual sink
dispatch (sink dispatch moves *into* the workflow's `dispatch-sinks` step). The ack mapping
becomes: `Completed (Right _)` → `AckOk`; `Completed (Left _)` → `AckRetry` (transient run
error, as today); `Suspended` → `AckOk` (the message is consumed; the parked workflow is now
tracked by its `keiro_workflows` instance row and the resume worker owns waking it).

A **resume worker** is added as a second long-running component. `runWorker` spawns (with
`Control.Concurrent.Async`) `runWorkflowResumeWorker (agentRunRegistry deps)` on the same
`Store` handle alongside the existing pgmq processor, so suspended workflows are rediscovered
and re-driven.

**Sink dispatch is a transactional outbox, not a synchronous POST (audit item C3, resolved as
Option 3 — the production model for kikan).** The `dispatch-sinks` step does **not** POST to
`kawa`/`kizashi`/`rei`/`danwa` inline. For each sink the permission gate allows, it calls keiro's
`enqueueOutboxTx :: OutboxMessage -> Tx.Transaction ()` to write a sink-intent row into
`kiroku.keiro_outbox` **in the same transaction as the journal step** — so the enqueue is
exactly-once with the run's progress and a crash cannot lose or double-write it. The `OutboxMessage`'s
`message_id` is **deterministic** from `(WorkflowId, sinkIndex)`, so the unique `(source, message_id)`
constraint on `keiro_outbox` makes a replayed step a no-op. A denied sink is logged and skipped, with no
row written, exactly as today. A **fourth long-running component**, the **outbox publisher**, then runs
`Keiro.Outbox.publishClaimedOutbox shikigamiSinkPublish opts (Just metrics)` concurrently in
`runWorker`; `shikigamiSinkPublish :: OutboxRow -> Eff es PublishOutcome` decodes the sink intent and
performs the actual HTTP POST through the existing `Shikigami/Sink/*Client.hs`, passing the row's
`message_id` as the destination idempotency key. Delivery is therefore at-least-once and decoupled from
the run: a slow or down sink endpoint no longer stalls the workflow, and `keiro_outbox`'s
`status`/`next_attempt_at` columns drive retry/backoff. (A later evolution, aligned with kikan's
event-driven model, is to make sinks first-class integration events the sink services *consume* rather
than HTTP POSTs; that depends on those services and is out of scope here. The outbox mechanism is the
same either way.)

**Commands.** `cabal build shikigami-core`; `cabal test shikigami-core-test`.

**Acceptance.**
1. The existing run tests still pass (behavior preserved): a triggered run opens a session,
   recalls, runs the behavior, dispatches its sinks, records a memory, and completes.
2. A new test drives `agentRunWorkflow` with an injected fault: a `runBehaviorStep` (or a
   later step) whose body throws on its first invocation but succeeds on the second. Running
   the workflow twice (simulating crash + resume) shows the earlier steps' bodies executed
   exactly once (verified by counters), and the second run reaches `Completed`. Inspecting
   `keiro_workflow_steps` for that `WorkflowId` shows one row per completed step.

### Milestone 3 — `awaitApproval` / `awaitInput`: park and resume on an answer

**Scope.** Add the durable suspend-point combinator and wire it into the workflow before sink
dispatch, gated by a policy hook. Prove a run parks and an answer event resumes it.

**What will exist at the end.** A new module
`/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-core/src/Shikigami/Agent/Approval.hs`:

```haskell
data ApprovalRequest = ApprovalRequest
  { approvalPrompt  :: !Text
  , approvalContext :: !Value
  , approvalChannel :: !ApprovalChannel   -- ViaKizashi | ViaDanwa
  }

data ApprovalDecision = Approved !Value | Rejected !Text | TimedOut
  deriving (Generic)   -- ToJSON/FromJSON: the journaled answer

-- | A durable park-and-resume point. Registers an awakeable, posts the ask once
-- (idempotently) via the chosen channel, records park state, then suspends until the answer
-- (or, in M4, a deadline timer) signals the awakeable.
awaitApproval ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  ApprovalEnv ->
  StepName ->            -- unique label for this suspension point within the run
  ApprovalRequest ->
  Maybe NominalDiffTime -> -- optional deadline (armed in M4; ignored/None in M3)
  Eff es ApprovalDecision

-- | The GENERIC durable input channel (added in the cross-plan coherence review, 2026-06-27, to
-- satisfy plan 8). Suspend the run until an external caller delivers a payload addressed to THIS
-- workflow by its WorkflowId + StepName — no approve/reject semantics, any JSON payload. This is the
-- base primitive the danwa conversational loop (plan 8) and any flow awaiting a free-form message
-- consume directly. It is built on keiro `awakeableNamed`, but addressing is by (WorkflowId, StepName)
-- so a caller that knows only the run's id can resume it.
awaitInput ::
  (Workflow :> es, Store :> es, IOE :> es, FromJSON a) =>
  StepName -> Eff es a

-- | Deliver a payload to a parked run's `awaitInput`, addressed by workflow id + step name. Returns
-- True if a parked run was resumed, False if none was waiting. Resolves the awakeable id recorded for
-- (WorkflowId, StepName) under the hood, so the caller needs only the run's id (e.g. plan 8's danwa
-- bridge knows the conversation id = workflow id, not the awakeable id).
deliverInput ::
  (Store :> es, IOE :> es, ToJSON a) =>
  WorkflowId -> StepName -> a -> Eff es Bool

-- | awaitApproval (above) is the typed approval *specialisation* of awaitInput: it wraps the generic
-- channel with the ApprovalRequest ask + Approved/Rejected/TimedOut answer. resolveApproval is its
-- specialised resume seam; internally it may be expressed over deliverInput keyed by
-- (WorkflowId, StepName), or keep the AwakeableId form for callers that already hold the id.
resolveApproval :: AppEnv -> AwakeableId -> ApprovalDecision -> IO Bool
```

To support addressing by (WorkflowId, StepName), `awaitInput` records the mapping
`(WorkflowId, StepName) -> AwakeableId` when it arms the awakeable (an additive column on the same park
record `recordPark` already writes), and `deliverInput` looks it up before signalling. This is the only
new storage `awaitInput`/`deliverInput` need beyond what `awaitApproval` already records.

`ApprovalEnv` carries the three dependency hooks, each stubbed now and swapped later:

- `requiresApproval :: AgentIdentity -> SinkKind -> Value -> IO ApprovalRequirement` — the
  policy. **Stub:** a static table (e.g. "rei actions for agent X require approval").
  **Later:** the `en` repo plan "Per-action authorization..." replaces the body.
- `recordPark :: SessionId -> AwakeableId -> ApprovalRequest -> IO ()` — persists the durable
  park state. **Stub:** log only. **Later:** the kioku repo plan "Awaiting session state for
  durable park-and-resume" records an `Awaiting` session vertex + continuation here.
- `postAsk :: ApprovalChannel -> ApprovalRequest -> AwakeableId -> IO ()` — sends the ask.
  **Implemented now** by reusing the existing kizashi/danwa sink clients
  (`Shikigami/Sink/KizashiClient.hs`, `Shikigami/Sink/Danwa.hs`); the `AwakeableId` is
  embedded so the answer can be routed back.

`awaitApproval` is implemented on keiro's awakeable:

```haskell
awaitApproval env stepName req _deadline = do
  (aid, awaitAnswer) <- awakeableNamed stepName            -- stable, journaled promise
  _ <- step (stepName <> ":notify") $ liftIO $ do          -- runs once, idempotently
         recordPark env (currentSession env) aid req
         postAsk    env (approvalChannel req) req aid
         pure ()
  -- (M4) when a deadline is given, arm a keiro timer here that will signalAwakeable aid TimedOut
  awaitAnswer                                              -- SUSPEND until signalled
```

The workflow gate (in `Shikigami/Agent/Workflow.hs`, between `run-behavior` and
`dispatch-sinks`) consults the policy and, when required, calls `awaitApproval`; a `Rejected`
or `TimedOut` decision short-circuits sink dispatch (the run records the outcome and completes
without acting), while `Approved` proceeds.

The inbound answer arrives as an *addressed event* — the same path
`Shikigami/Trigger/Enqueue.hs` already uses for event-triggered runs. We add a small handler
that, given an `(AwakeableId, ApprovalDecision)` payload, calls `resolveApproval`, which calls
`signalAwakeable`. The resume worker from M2 then rediscovers the now-answerable workflow and
drives it past the `awaitAnswer`.

**Commands.** `cabal build shikigami-core`; `cabal test shikigami-core-test
--test-options='-p Approval'`.

**Acceptance.** A test agent whose policy requires approval for its sink: running it returns
`Suspended` (the workflow parked at `awaitApproval`); `keiro_awakeables` has a `pending` row
and `keiro_workflows` shows the instance suspended; no sink was dispatched yet. Then calling
`resolveApproval aid (Approved ...)` (or driving the inbound-event handler) followed by one
pass of `resumeWorkflowsOnce` drives the workflow to `Completed` and the sink is dispatched
exactly once. A second test with `Rejected` completes the run without dispatching the sink.

### Milestone 4 — Deadlines via keiro timers

**Scope.** Give `awaitApproval` an optional deadline so a parked run resumes with `TimedOut`
if no answer arrives in time.

**What will exist at the end.** When `awaitApproval` is given `Just deadline`, its `:notify`
step also arms a keiro timer whose payload encodes the awakeable id and a `TimedOut` decision.
The worker process runs keiro's `runWorkflowTimerWorker` (third long-running component, on the
same `Store` handle), supplying a fallback fire action that, for shikigami approval-timeout
payloads, calls `signalAwakeable aid TimedOut`. Because `signalAwakeable` is idempotent and
single-transition, whichever of the human answer or the timer fires first wins; the loser is a
no-op.

The exact timer-arming call is determined during implementation by reading
`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow/Sleep.hs` and the `keiro_timers`
schema: either `sleepNamed` with a follow-on step that signals on wake, or a directly-inserted
timer row routed to the fallback fire action. The plan's M4 first task is a 30-minute spike to
pick the cleaner of the two against the real API, recorded in the Decision Log.

**Commands.** `cabal build shikigami-core`; `cabal test shikigami-core-test
--test-options='-p Deadline'`.

**Acceptance.** A test agent that requires approval with a 1-second deadline: running it
parks (`Suspended`); without ever calling `resolveApproval`, after the timer is due and the
timer worker runs, one pass of `resumeWorkflowsOnce` drives the workflow to `Completed` with an
`ApprovalDecision` of `TimedOut`, and the sink is *not* dispatched. A companion test shows
that if the answer arrives before the deadline, the run completes with `Approved` and the late
timer fire is a no-op.


## Concrete Steps

Run everything from the shikigami working tree unless stated otherwise. First enter the dev
shell once per terminal session:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
nix develop
```

### Step 0 — Baseline: build and migrate

```bash
cabal build all
just create-database
```

Expected (abbreviated):

```text
Up to date            # or compilation lines on first build
...
codd: applied N migrations   # create-database runs `just migrate`
```

Confirm the keiro workflow tables are present (this proves M1's "no migration wiring needed"
finding):

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c "\dt kiroku.keiro_*"
```

Expected to include:

```text
 keiro_awakeables
 keiro_timers
 keiro_workflow_children
 keiro_workflow_steps
 keiro_workflows
```

Record this in Progress as the M1 migration finding.

### Step 1 — M1 spike

Read the keiro example first:

```bash
sed -n '140,240p' /Users/shinzui/Keikaku/bokuno/keiro/jitsurei/src/Jitsurei/DurableWorkflow.hs
```

Create `shikigami-core/test/Shikigami/SpikeWorkflowSpec.hs` with a two-step workflow that
increments a shared `IORef` inside `step "one"`, then (on the first pass only) throws after
step one; the test runs the workflow twice on the same `WorkflowId` and asserts the `IORef`
ended at 1, proving step one replayed from the journal. Use the effect stack shown in
`runAgentRunWorkflow` above, taking the `KirokuStore` from a test `AppEnv` (the test suite
already constructs one — see existing tests under `shikigami-core/test/`). Add the module to
`other-modules` in `shikigami-core/shikigami-core.cabal`'s `shikigami-core-test` stanza.

```bash
cabal test shikigami-core-test --test-options='-p Spike'
```

Expected:

```text
Spike
  replays the first step after a crash [OK]
All N tests passed
```

If this fails to compile because the `Store` handle type does not line up, re-read
`/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/App.hs` and
`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow.hs` imports — both use
`Kiroku.Store.Effect.Store`; the fix is to match `runStorePool (store env)` exactly as
`runAppIO` does.

### Step 2 — M2 workflow module

Create `shikigami-core/src/Shikigami/Agent/Workflow.hs` as described in Milestone 2. Lift the
bodies of the existing `Shikigami/Agent/Run.hs` phases into `step`s. Add the module to
`exposed-modules` in `shikigami-core/shikigami-core.cabal`. Build:

```bash
cabal build shikigami-core
```

Then edit `Shikigami/Worker.hs` `runOneAgent` to call `runAgentRunWorkflow` and map the
`WorkflowOutcome`, and edit `runWorker` to also launch `runWorkflowResumeWorker
(agentRunRegistry deps)` via `Control.Concurrent.Async.concurrently_`. Build again, then test:

```bash
cabal build shikigami-core
cabal test shikigami-core-test
```

Expected: the existing run-lifecycle tests pass unchanged, and the new crash-resume test
passes. Spot-check the journal:

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "SELECT step_name FROM kiroku.keiro_workflow_steps WHERE workflow_name='shikigami.agent-run' ORDER BY step_name;"
```

Expected step names include `complete`, `dispatch-sinks`, `ingest-job`, `lookup-agent`,
`open-session`, `recall`, `record`, `run-behavior`.

### Step 3 — M3 approval combinator

Create `shikigami-core/src/Shikigami/Agent/Approval.hs` and add it to `exposed-modules`. Wire
`awaitApproval` into the workflow gate. Build and test:

```bash
cabal build shikigami-core
cabal test shikigami-core-test --test-options='-p Approval'
```

Expected: the park test returns `Suspended`; after `resolveApproval`/resume it reaches
`Completed` and dispatches the sink once. Inspect the pending promise while parked:

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "SELECT status FROM kiroku.keiro_awakeables ORDER BY created_at DESC LIMIT 1;"
```

Expected `pending` while parked, `completed` after the answer.

### Step 4 — M4 deadline

First spike the timer-arming approach (Decision Log entry), then implement it and run
`runWorkflowTimerWorker` in `runWorker`. Build and test:

```bash
cabal build shikigami-core
cabal test shikigami-core-test --test-options='-p Deadline'
```

Expected: the deadline test reaches `Completed` with `TimedOut` after the timer fires, with no
sink dispatched.

### Step 5 — Full suite and clean re-run

```bash
cabal test shikigami-core-test
```

Run twice in a row; the second run must produce identical results (idempotence — see below).


## Validation and Acceptance

The change is validated by observable behavior, not by compilation alone.

**Behavior preserved (M2).** Running any existing agent end-to-end produces the same external
effects as before: a kioku session is opened and completed, prior memories are recalled, the
behavior output is dispatched to the declared sinks (kawa/kizashi/rei/danwa) subject to the
existing `checkGrant` gate, and a `MemoryPattern` memory is recorded scoped to the agent. The
pre-existing `shikigami-core-test` lifecycle tests pass unchanged.

**Crash recovery (M2).** With the fault-injection test, a run that fails partway through and
is re-driven completes without repeating the side effects of the steps that already finished.
Evidence: per-step counters show each completed step's body ran once; `keiro_workflow_steps`
shows one journaled row per completed step for that `WorkflowId`; the second drive reaches
`Completed`. A manual version: start `runWorker`, enqueue a run, `kill -9` the worker while the
run is between steps (insert a temporary delay in one step body to widen the window), restart
`runWorker`, and observe the resume worker finish the run without duplicate sink posts.

**Park and resume on answer (M3).** A run whose policy requires approval returns `Suspended`;
`keiro_awakeables` shows a `pending` row and no sink has been dispatched. Supplying the answer
(`resolveApproval aid (Approved …)`, then a resume pass) drives the run to `Completed` and the
sink is dispatched exactly once. A `Rejected` answer completes the run with the sink
suppressed.

**Deadline (M4).** A run parked with a 1-second deadline, left unanswered, resumes with a
`TimedOut` decision after the timer worker fires the deadline timer; the sink is suppressed. An
answered-before-deadline run completes with `Approved` and the late timer fire is a no-op
(`signalAwakeable` returns `False`).

All four are covered by automated tests in `shikigami-core-test`, selectable with
`--test-options='-p <Spike|Approval|Deadline>'`, plus the always-on lifecycle and crash-resume
tests.


## Idempotence and Recovery

Every database step in this plan is safe to repeat. `just create-database` and `just migrate`
are idempotent (codd records applied migrations and skips them; the keiro tables use
`CREATE ... IF NOT EXISTS`). The tests bring up an ephemeral Postgres, so re-running
`cabal test shikigami-core-test` is safe and repeatable.

Within the runtime, idempotence is the core guarantee keiro provides and that this plan must
respect:

- **Step bodies must be idempotent** because step side effects are at-least-once across a
  crash between the effect and the journal commit. The risky bodies here are `dispatch-sinks`
  (posting to kawa/kizashi/rei/danwa) and the approval `:notify` (posting the ask). Both must
  derive an idempotency key from the workflow identity and step name. The kawa/kizashi clients
  already mint deterministic activity/signal ids per run ordinal; carry the `WorkflowId` +
  `StepName` into those keys so a replayed post is deduplicated by the downstream service.
- **`WorkflowId` = `RunJob.idempotencyKey`** ensures the same trigger maps to the same
  workflow; enqueuing the same job twice resumes/continues one workflow rather than starting
  two.
- **`awaitApproval` arming is idempotent**: `awakeableNamed` returns a stable journaled id and
  the `:notify` step runs once; on resume the step is a journal hit, so the ask is not
  re-posted.
- **`signalAwakeable` is single-transition**: a duplicate answer (or an answer racing a
  deadline timer) returns `False` and changes nothing.

Recovery paths: a crashed worker loses nothing — the resume worker rediscovers unfinished
workflows from `keiro_workflows` and re-drives them from the journal. A parked run with a lost
answer is recovered by re-sending the answer event (idempotent) or, if a deadline was set, by
the deadline timer. To abandon a parked run, call `cancelAwakeable` (the await then raises a
cancellation the workflow body can treat as `Rejected`). Rolling back the code change is safe:
revert `Worker.hs` to call `runAgentWithMemory` directly; in-flight journaled workflows are
inert data and harm nothing.


## Interfaces and Dependencies

### Libraries and modules consumed

- **`Keiro.Workflow`** (`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow.hs`):
  `Workflow`, `step`, `awaitStep`, `runWorkflow`, `runWorkflowWith`, `WorkflowOutcome
  (Completed | Suspended)`, `WorkflowName`, `WorkflowId`, `StepName`.
- **`Keiro.Workflow.Awakeable`**: `awakeableNamed`, `signalAwakeable`, `cancelAwakeable`,
  `AwakeableId`.
- **`Keiro.Workflow.Sleep`**: `sleepNamed`, `runWorkflowTimerWorker` (M4).
- **`Keiro.Workflow.Resume`**: `WorkflowRegistry`, `WorkflowDef`, `resumeWorkflowsOnce`,
  `runWorkflowResumeWorker`.
- **`Keiro.Outbox`** (`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Outbox.hs`): the
  transactional sink-dispatch queue — `enqueueOutboxTx :: OutboxMessage -> Tx.Transaction ()`
  (called inside the `dispatch-sinks` step's transaction, exactly-once via the unique
  `(source, message_id)` key), `OutboxMessage (..)`, `OutboxRow (..)`, `PublishOutcome (..)`,
  `OutboxPublishOptions`, and `publishClaimedOutbox :: … -> (OutboxRow -> Eff es PublishOutcome) -> … -> Eff es OutboxPublishSummary`
  (the outbox publisher worker; shikigami supplies `shikigamiSinkPublish` to HTTP-POST through the
  existing sink clients with the row's `message_id` as the idempotency key).
- **`Kioku.App`** (`/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/App.hs`):
  `AppEnv (..)`, `AppEffects`, `runAppIO` (pattern to mirror), and the `store :: KirokuStore`
  field reused as the keiro `Store` handle.
- **`Kiroku.Store.Effect`**: `Store`, `runStorePool` (the interpreter that both kioku and the
  keiro workflow runtime require).
- Existing shikigami modules reused inside step bodies: `Shikigami.Agent.Run`
  (`runAgentWithMemory`'s phase helpers, refactored to be callable per-step),
  `Shikigami.Behavior.Run` (`runBehavior`), `Shikigami.Sink` (`dispatch`),
  `Shikigami.Sink.KizashiClient`, `Shikigami.Sink.Danwa` (the approval ask channel),
  `Shikigami.Trigger.Enqueue` (`RunJob`).

### New modules and the signatures that must exist

At the end of **M2**, `/Users/shinzui/.../shikigami-core/src/Shikigami/Agent/Workflow.hs`
exports:

```haskell
data AgentRunDeps = AgentRunDeps
  { appEnv      :: !AppEnv
  , behaviorEnv :: !BehaviorEnv
  , agents      :: ![AgentDecl]
  , kizashi     :: !KizashiConfig
  , kawa        :: !KawaConfig
  }

agentRunWorkflowName :: WorkflowName

agentRunWorkflow ::
  AgentRunDeps -> Maybe RunJob -> Eff (Workflow : AppEffects) (Either Text AgentRunResult)

runAgentRunWorkflow ::
  AgentRunDeps -> RunJob -> IO (Either StoreError (WorkflowOutcome (Either Text AgentRunResult)))

agentRunRegistry :: AgentRunDeps -> WorkflowRegistry AppEffects
```

`Shikigami/Worker.hs` after M2: `runOneAgent` calls `runAgentRunWorkflow` and maps the
outcome to an `AckDecision`; `runWorker` runs the pgmq processor and
`runWorkflowResumeWorker (agentRunRegistry deps)` concurrently on `store workerAppEnv`.

At the end of **M3**, `/Users/shinzui/.../shikigami-core/src/Shikigami/Agent/Approval.hs`
exports `ApprovalRequest`, `ApprovalChannel`, `ApprovalDecision`, `ApprovalRequirement`,
`ApprovalEnv`, `awaitApproval`, the generic `awaitInput :: (… , FromJSON a) => StepName -> Eff es a`
and `deliverInput :: (… , ToJSON a) => WorkflowId -> StepName -> a -> Eff es Bool`, and
`resolveApproval` with the signatures shown in Milestone 3. `Shikigami/Agent/Workflow.hs` gains the
policy-gated `awaitApproval` call between the `run-behavior` and `dispatch-sinks` steps.

At the end of **M4**, `awaitApproval`'s deadline branch arms a keiro timer, and `runWorker`
additionally runs `runWorkflowTimerWorker` with a shikigami fallback fire action that calls
`signalAwakeable aid TimedOut` for approval-timeout payloads.

### Cross-plan dependencies (in other repositories)

These are referenced, not implemented, here. Each is hidden behind a hook so this plan ships
and tests independently with a stub.

- **kioku repo, plan "Awaiting session state for durable park-and-resume."** Provides the
  durable park state (an `Awaiting` session vertex + continuation) recorded by this plan's
  `recordPark` hook. Until it lands, `recordPark` logs only; the keiro awakeable already
  provides durable resumability, so park/resume works without it (the kioku state adds
  first-class visibility of "this session is awaiting").
- **en repo, plan "Per-action authorization..."** Provides the policy that decides when
  `awaitApproval` is required, behind the `requiresApproval` hook (a static table until then).
- **kizashi / danwa.** The approval *channel* — implemented now by reusing the existing
  kizashi and danwa sink clients in the `postAsk` hook.

### Downstream plans that build on this keystone

This plan is the prerequisite for three sibling shikigami plans, which must not be started
before M2 lands: plan 8 (the interactive conversational loop — a long-lived workflow that
suspends between turns using the same `awaitStep`/awakeable machinery), plan 9 (multi-agent
delegation — `spawnChild`/`awaitChild`), and plan 10 (the timer-driven scheduler, run-as-
workflow journaling for mid-turn resume, and wiring real OTel tracing to drop
`runTracingNoop`).


---

Revision note: Initial authored version. Grounds the design in the real keiro workflow API
(`Keiro.Workflow.step/awaitStep/runWorkflow`, `Keiro.Workflow.Awakeable.awakeableNamed/
signalAwakeable`, `Keiro.Workflow.Sleep.runWorkflowTimerWorker`, `Keiro.Workflow.Resume`) and
on two simplifying discoveries from the working tree: (1) kioku's `AppEnv` already carries the
`KirokuStore` that the keiro `Workflow` effect needs, so the workflow runs on the same event
store with no new connection and the workflow body shares kioku's `AppEffects` row; and (2)
keiro's workflow tables are already applied by shikigami's migrations transitively through
`kiokuMigrations`, so no migration wiring is required. Scope decisions (keiro vs ad-hoc, where
the `awaitApproval` seam sits, what is deferred to kioku/en/kizashi/danwa) are recorded in the
Decision Log.


## Revision Notes

- 2026-06-27 — **Cross-plan coherence pass (plans 7–11).** This plan is the substrate keystone and was
  the source of truth in the audit; its design is unchanged. One Decision Log entry was added recording
  that this plan's `runWorkflowTimerWorker` is the single shared timer-worker entrypoint, with plan 10's
  scheduled-agent timers routed through the same `shikigamiTimerFallback` (by payload `kind`) rather than
  a competing worker loop. Siblings were aligned to this plan's actual names elsewhere: plan 10 now
  consumes `agentRunWorkflow`/`agentRunWorkflowName "shikigami.agent-run"` instead of a divergent 5-step
  `WorkflowName "agent-run"`; plan 9 corrected "registry keyed by agent name" to the single constant
  workflow name with agent identity in the `RunJob`; plan 11 pinned `awaitAcknowledgement` to this plan's
  `awaitApproval` signature and noted its dependency on this plan's Milestone 4 deadline timer.
  **C2 is now resolved** (see the Decision Log and Milestone 3): this plan exposes a generic
  `WorkflowId`-keyed `awaitInput`/`deliverInput` as the base primitive, with `awaitApproval` recast as a
  specialisation; plan 8 cites the generic signature. **C3 is now resolved as Option 3** (see the
  Decision Log and the worker-components prose in Milestone 2): the `dispatch-sinks` step enqueues sink
  intents into the keiro transactional outbox (`kiroku.keiro_outbox`) in the journal transaction, and a
  separate outbox-publisher worker delivers them at-least-once and idempotently — the production model for
  kikan, replacing both the synchronous in-step POST and any after-`Completed` dispatch.
