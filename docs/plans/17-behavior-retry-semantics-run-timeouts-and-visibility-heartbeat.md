---
id: 17
slug: behavior-retry-semantics-run-timeouts-and-visibility-heartbeat
title: "Behavior retry semantics, run timeouts, and visibility heartbeat"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tykwvek587vr2gwtcf81j"
master_plan: "docs/masterplans/3-correctness-and-delivery-semantics-stop-dropping-and-duplicating-work.md"
---

# Behavior retry semantics, run timeouts, and visibility heartbeat

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, a shikigami agent whose behavior fails once — a flaky LLM call, a downstream HTTP 503 — never recovers. The failure is journaled as the durable result of the `run-behavior` workflow step, so every "retry" replays the recorded failure from the journal without re-executing anything, and after three such replays the job is silently archived. Separately, any run that takes longer than 30 seconds (which is to say: any real LLM call) is redelivered by the queue while still executing, spawning a concurrent duplicate that dies on a journal conflict. There is no wall-clock limit on a run at all.

After this plan, transient behavior failures are genuinely re-executed on redelivery and eventually succeed; permanent failures (unknown task, malformed skill) are dead-lettered to an inspectable queue instead of being retried pointlessly and silently archived; a handler heartbeats the queue's visibility timeout while a long run is in flight so the job is never redelivered mid-execution; and every run has an explicit, configurable wall-clock budget. You can see it working by running the new test module `Shikigami.RetrySemanticsSpec` (fails before, passes after) and by watching a worker process a deliberately slow agent without ever logging a `JournalAppendConflict`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: add `FailureClass`/`classifyRunError`/`TransientBehaviorFailure` to `Shikigami.Behavior.Error`; throw transients in `runBehaviorStep`.
- [ ] Milestone 1: tests — transient failure re-executes on second run; permanent failure replays without re-execution.
- [ ] Prerequisites: plans 36/37 complete; worker ownership and Settei configuration are settled.
- [ ] Milestone 2: extract pure `classifyOutcome`; preserve shibuya as sole ack owner; normalize PGMQ's one-based attempt and use the shared `mkRetryPolicy`; configure a real dead-letter queue.
- [ ] Milestone 2: tests — classification table test; dead-letter queue receives permanent failures.
- [ ] Milestone 3: thread the shibuya lease into `handleRunJob`; periodic heartbeat around the workflow execution.
- [ ] Milestone 3: test — pgmq visibility-extension primitive prevents redelivery.
- [ ] Milestone 4: wall-clock run timeout (`runTimeout`) and configurable approval `deadline` in `WorkerEnv`; Settei wiring.
- [ ] Milestone 4: test — a run exceeding the budget yields a retry decision and completes on the next attempt.
- [ ] Register `Shikigami.RetrySemanticsSpec` in `shikigami-core.cabal` and `shikigami-core/test/Main.hs`; `cabal build all` and `cabal test all` green under `nix develop`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Express transient failures by throwing `TransientBehaviorFailure` from inside the step body instead of journaling a `Left`, rather than rotating a retry generation into the step name or adding a retry wrapper.
  Rationale: Verified keiro semantics (keiro `src/Keiro/Workflow.hs`, `Step` handler: the journal append happens only after the step body returns a value; a thrown exception propagates un-journaled, so the step re-runs on the next execution). This is keiro's documented contract — "step side effects are at-least-once; bodies must be idempotent" — and needs no new framework features. Step-name rotation would violate the additive-only journal discipline of docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md.
  Date: 2026-07-08

- Decision: Keep `agentRunWorkflow`'s result type `Either Text AgentRunResult` unchanged; after this plan a journaled `Left` means "permanent failure" by construction, and the worker dead-letters all `Completed (Left _)` outcomes.
  Rationale: keiro journals the workflow completion value; changing the type would change the JSON encoding of already-completed workflows. Keeping it also deletes the `"unknown agent "` string-prefix hack for free: unknown-agent is just another permanent `Left`.
  Date: 2026-07-08

- Decision: Keep the pgmq visibility timeout at 30 seconds and add a lease heartbeat, rather than raising the visibility timeout to cover the longest imaginable run.
  Rationale: A large static timeout delays redelivery after a genuine worker crash by the full window; a heartbeat keeps crash-recovery latency at ~30s while protecting arbitrarily long healthy runs. The pinned shibuya (`cabal.project` tag `3f276ee`) already exposes `lease :: Maybe (Lease es)` on `Ingested` and the pinned shibuya-pgmq-adapter populates it via pgmq `set_vt`, so no dependency bump is needed.
  Date: 2026-07-08

- Decision: Classify `RunError` conservatively: `UnknownTask`, `SkillLoadFailed`, `UnsupportedBehavior` are permanent; `ProgramFailed`, `SkillRunFailed` are transient.
  Rationale: The permanent three are configuration errors that no retry can fix. The transient two wrap provider/tool execution and are where flaky LLM/HTTP failures surface; misclassifying a truly-permanent program bug as transient costs bounded retries (maxRetries=3) and then a dead-letter, which is inspectable — the safe failure mode.
  Date: 2026-07-08

- Decision: On run timeout, return a retry decision (not dead-letter).
  Rationale: The journal preserves all completed steps, so the retry resumes from the last journaled step rather than restarting; a slow run frequently completes within a second budget. Repeated timeouts exhaust `maxRetries` and land in the dead-letter queue anyway.
  Date: 2026-07-08
- Decision: PGMQ delivery attempts are one-based. Normalize that value once at the
  adapter boundary and build delays/ceilings with the shared `mkRetryPolicy`; do not
  reinterpret `Envelope.attempt` as zero-based.
  Rationale: the old formula is off by one against PGMQ `read_ct` and would reach retry
  ceilings/delays at different deliveries than the framework.
  Date: 2026-07-22
- Decision: The shibuya handler returns exactly one `AckDecision`; it never deletes,
  archives, commits, or moves the message directly.
  Rationale: framework-owned acknowledgement preserves transactional DLQ behavior and
  prevents duplicate finalization.
  Date: 2026-07-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Shikigami runs declared agents. A "run job" (`RunJob` in `shikigami-api/src/Shikigami/Api/RunJob.hs`) sits on a Postgres-backed message queue (pgmq) named `shikigami_run_jobs`. The worker in `shikigami-core/src/Shikigami/Worker.hs` drains that queue using shibuya, a queue-processing framework: `runQueueWorker` (Worker.hs:72-84) builds a pgmq adapter with `defaultConfig runQueueName` (Worker.hs:76) and registers `runJobHandler` (Worker.hs:126-128), which delegates to `handleRunJob` (Worker.hs:132-141). For an ordinary job, `runOneAgent` (Worker.hs:165-192) executes the agent as a keiro durable workflow via `AgentWorkflow.runAgentRunWorkflow` and maps the outcome to a shibuya `AckDecision` (`AckOk`, `AckRetry`, `AckDeadLetter` — defined in shibuya-core `Shibuya.Core.Ack`).

A keiro durable workflow (defined in `shikigami-core/src/Shikigami/Agent/Workflow.hs`) is a sequence of named steps whose results are journaled in Postgres: `step name action` runs `action` only if the journal has no entry for `name`; otherwise it "replays" — returns the journaled value without executing. The agent workflow's steps are `ingest-job`, `lookup-agent`, `open-session`, `recall`, `run-behavior`, `dispatch-sinks`, `record`, `complete` (see `expectedLifecycleSteps` in `shikigami-core/test/Shikigami/AgentWorkflowSpec.hs:565-576`). The workflow id is the job's idempotency key (Workflow.hs:152), so a redelivered job re-enters the same journal.

The three verified bugs this plan fixes:

First, journaled failures. `runResolvedAgent` runs the behavior inside a journaled step: `runStep deps (StepName "run-behavior") (runBehaviorStep deps sid decl job)` (Workflow.hs:182). `runBehaviorStep` (Workflow.hs:277-289) returns `Either Text Value` — including `Left` for failures (line 289 maps `runBehavior`'s `Either RunError Value` to `Either Text Value`). Because keiro's `step` journals whatever the body returns (verified in keiro `src/Keiro/Workflow.hs`: the `Step` handler runs the body, then appends `StepRecorded` — an exception thrown by the body propagates without journaling), a transient `Left` becomes the step's permanent recorded result. The worker sees `Completed (Left err)` and returns `AckRetry (RetryDelay 1s)` (Worker.hs:183-186), the queue redelivers, the workflow replays the journaled `Left` without executing anything, and after `maxRetries = 3` deliveries the pgmq adapter silently archives the message (pinned shibuya-pgmq-adapter `Shibuya/Adapter/Pgmq/Internal.hs`: `readCount > maxRetries` finalizes `AckDeadLetter MaxRetriesExceeded`, and with `deadLetterConfig = Nothing` that finalizer archives). Net effect: every behavior failure is permanent, and the "retries" burn queue deliveries on pure journal replays.

Second, mid-flight redelivery. `defaultConfig` (shibuya-pgmq-adapter `Shibuya/Adapter/Pgmq/Config.hs:279-293` in the canonical checkout at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter`; identical values in the pinned copy under `dist-newstyle/src/shibuya-p_-*`) sets `visibilityTimeout = 30`, `batchSize = 1`, `maxRetries = 3`, `deadLetterConfig = Nothing`. Any handler running longer than 30 seconds has its message redelivered while still executing. The duplicate executes the same `WorkflowId` concurrently; the loser of the journal race hits `JournalAppendConflict`, which `enqueueSinkIntents` converts to `ioError` (Workflow.hs:411-415) and which keiro's own step runtime converts to a thrown `WorkflowJournalAppendError`. The shibuya `Lease` capability (`Shibuya.Core.Lease`: `Lease { leaseId :: Text, leaseExtend :: NominalDiffTime -> Eff es () }`) is already delivered to the handler — the pinned `Ingested` record has `lease :: !(Maybe (Lease es))` and the pinned adapter constructs it over pgmq `set_vt` — but `runJobHandler` (Worker.hs:127) pattern-matches only the envelope and drops it.

Third, no run timeout. `agentRunDeps` hardcodes `deadline = Nothing` (Worker.hs:205); the `deadline` field of `AgentRunDeps` (Workflow.hs:88) only bounds approval waits (Workflow.hs:239) and the flow acknowledgement deadline (Workflow.hs:313). Nothing bounds the run's wall clock — `System.Timeout` appears nowhere in the repository.

Additionally, the ack mapping in `runOneAgent` (Worker.hs:174-192) uses a fixed one-second `AckRetry` for every retryable case and detects the only dead-letter case by the string prefix `"unknown agent "` (Worker.hs:184) — matching the `Left` produced at Workflow.hs:137. With `deadLetterConfig = Nothing`, even explicit `AckDeadLetter` decisions merely archive the message with no queue to inspect.

Terms: "visibility timeout" is pgmq's redelivery window — a read message stays invisible to other readers for that many seconds, after which it is redelivered; "heartbeat"/"lease extension" means pushing that window forward (`pgmq.set_vt`) while still working; "dead-letter queue" (DLQ) is a second pgmq queue that receives messages the worker refuses to process, instead of archiving them out of sight; "transient" failures are ones a retry can fix (network, rate limits), "permanent" ones it cannot (unknown task name).

Test infrastructure: specs under `shikigami-core/test/` run against a real Postgres provisioned per test by `withShikigamiMigratedDatabase` (`shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs`), which applies all migrations including the pgmq schema. `Shikigami.AgentWorkflowSpec` shows the established pattern, including `AgentRunHooks` (Workflow.hs:91-94) — test-only callbacks invoked before/after each step body, used to count executions and inject crashes (see the "resumes after a crash" test at AgentWorkflowSpec.hs:67-114).


## Plan of Work

Milestone 1 — transient failures throw; permanent failures journal. Scope: `shikigami-core/src/Shikigami/Behavior/Error.hs`, `shikigami-core/src/Shikigami/Agent/Workflow.hs`, new test module. At the end, a behavior that fails transiently is re-executed (not replayed) on the next delivery of the same job, observable in a test that fails today.

In `Shikigami/Behavior/Error.hs`, add a classification and a dedicated exception:

```haskell
data FailureClass = Transient | Permanent
  deriving stock (Eq, Show)

classifyRunError :: RunError -> FailureClass
classifyRunError = \case
  UnknownTask _ -> Permanent
  SkillLoadFailed _ -> Permanent
  UnsupportedBehavior _ -> Permanent
  ProgramFailed _ -> Transient
  SkillRunFailed _ -> Transient

newtype TransientBehaviorFailure = TransientBehaviorFailure Text
  deriving stock (Show)

instance Exception TransientBehaviorFailure
```

In `Shikigami/Agent/Workflow.hs`, change the last arm of `runBehaviorStep` (currently line 289: `liftIO (first (Text.pack . show) <$> runBehavior (behaviorEnv deps) decl triggerPayload)`) to inspect the `RunError` before deciding: on `Left err` with `classifyRunError err == Transient`, `liftIO (throwIO (TransientBehaviorFailure (Text.pack (show err))))`; on `Permanent`, return `Left` as today; on `Right`, return `Right`. Because the throw happens inside the step body, keiro journals nothing, and the next delivery re-runs the body. The `Flow` and research-supervisor arms (Workflow.hs:286-288) are unchanged — flows already run their own journaled sub-steps and only return `Left` for the permanent "unknown flow" case (Workflow.hs:301).

Note the consequence, and record it in code comments: after this milestone, a journaled `Left` from `run-behavior` (and therefore a `Completed (Left _)` workflow outcome) means permanent by construction. The `fail-session` step (Workflow.hs:185) still runs for permanent failures, which is correct — the kioku session should be marked failed exactly when the failure is final.

Milestone 2 — typed ack classification, backoff, and a real DLQ. Scope: `shikigami-core/src/Shikigami/Worker.hs`. At the end, the worker's outcome→ack mapping is a pure, unit-testable function; retry delays grow with the delivery attempt; permanent failures land on a `shikigami_run_jobs_dlq` pgmq queue.

Extract from `runOneAgent` a pure function (exported for tests):

```haskell
classifyOutcome ::
  Maybe Attempt ->
  Either StoreError (WorkflowOutcome (Either Text AgentRunResult)) ->
  AckDecision
```

with this mapping: `Left storeErr` → `AckRetry (retryDelayFor attempt)` (transient infrastructure); `Right (Completed (Right _))` → `AckOk`; `Right (Completed (Left err))` → `AckDeadLetter (PoisonPill err)` (permanent by Milestone 1's construction — this deletes the `"unknown agent "` prefix match at Worker.hs:184-185); `Right Suspended` → `AckOk`; `Right ContinuedAsNew` → `AckOk`; `Right Cancelled` → `AckDeadLetter (PoisonPill …)` as today (Worker.hs:190); `Right Failed` → `AckRetry (retryDelayFor attempt)`. Treat PGMQ `read_ct`/the first delivery as attempt 1, normalize `Nothing` to that first attempt, and derive `retryDelayFor` from the shared `mkRetryPolicy` with an explicit cap. Do not duplicate exponential arithmetic in the worker. In `runOneAgent`, catch typed transient/framework errors and return the one `AckDecision` shibuya will finalize; do not manipulate the queue directly. `runConversationAgent` uses the same policy.

Configure the adapter with a DLQ: in `runQueueWorker` (Worker.hs:76), replace `defaultConfig runQueueName` with

```haskell
(defaultConfig runQueueName)
  { deadLetterConfig =
      Just DeadLetterConfig { dlqTarget = DirectQueue runDeadLetterQueueName, includeMetadata = True }
  }
```

where `runDeadLetterQueueName` parses `"shikigami_run_jobs_dlq"` (add it next to `runQueueName` in `shikigami-core/src/Shikigami/Trigger/Enqueue.hs`, and ensure the queue exists at worker startup with pgmq `createQueue` — coordinate with docs/plans/18, which introduces `ensureRunQueue`; and with docs/plans/20, which hardens this module). `DeadLetterConfig`/`DeadLetterTarget` come from `Shibuya.Adapter.Pgmq.Config`. With this set, both explicit `AckDeadLetter` decisions and `MaxRetriesExceeded` auto-dead-letters are moved to the DLQ transactionally instead of archived silently.

Milestone 3 — visibility heartbeat. Scope: `shikigami-core/src/Shikigami/Worker.hs`. At the end, a handler extends its message lease every 10 seconds for as long as the run executes, so a 5-minute LLM call is never redelivered mid-flight.

Change `runJobHandler` to keep the whole `Ingested` value: it already receives `Ingested { envelope, lease }` (the pinned shibuya-core `Shibuya.Core.Ingested` carries `lease :: !(Maybe (Lease es))`; `type Handler es msg = Ingested es msg -> Eff es AckDecision` at the pinned tag). Because `leaseExtend :: NominalDiffTime -> Eff es ()` lives in the handler's effect row but the heartbeat must tick concurrently with the IO orchestration, obtain an IO unlift with effectful's concurrent unlift — `withEffToIO (ConcUnlift Persistent (Limited 1))` from `Effectful` — and race the heartbeat against the work:

```haskell
runJobHandler env ingested@Ingested {envelope = Envelope {payload = p, attempt}} =
  withEffToIO (ConcUnlift Persistent (Limited 1)) \unlift ->
    withAsync (heartbeat unlift (lease ingested)) \_ ->
      handleRunJob env attempt p
  where
    heartbeat _ Nothing = pure ()
    heartbeat unlift (Just l) = forever do
      threadDelay 10_000_000
      unlift (leaseExtend l 30)
```

`withAsync` (from `async`, already a transitive dependency; add `async` to `shikigami-core.cabal` build-depends if not present) cancels the heartbeat when the handler returns. Each tick pushes visibility 30 seconds ahead; a crashed worker stops ticking and the message becomes visible within ~30 seconds — crash-recovery latency is unchanged. Thread `attempt` through to `handleRunJob`/`runOneAgent` for Milestone 2's backoff (change `handleRunJob :: WorkerEnv -> Value -> IO AckDecision` to `WorkerEnv -> Maybe Attempt -> Value -> IO AckDecision`).

Milestone 4 — explicit run timeout. Scope: the worker module assigned by plan 36 and
plan 37's Settei application config. At the end, every run has a wall-clock budget
(default 300 seconds) and the approval deadline is configurable instead of hardcoded `Nothing`.

Add to `WorkerEnv` two fields: `runTimeout :: !(Maybe NominalDiffTime)` and
`approvalDeadline :: !(Maybe NominalDiffTime)`. Wrap workflow execution with the
timeout and return the shared retry decision when it expires. Declare stable Settei
keys with explicit legacy bindings for `SHIKIGAMI_RUN_TIMEOUT_SECONDS` and
`SHIKIGAMI_APPROVAL_DEADLINE_SECONDS`; validate positivity/bounds before constructing
the environment. No worker module calls `lookupEnv`.

Journal-versioning constraint (applies to every milestone): no journaled step is renamed and no journaled value encoding changes; the only observable-journal change in this plan is that transient failures stop producing journal entries at all, which is strictly additive-safe per docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikigami`, inside the dev shell (`nix develop`), which provides GHC, cabal, and a Postgres reachable via the `PG*` environment variables.

Edit the files as described in Plan of Work, in milestone order. After each milestone:

```bash
nix develop -c cabal build all
```

Expected: compiles with no errors (warnings-as-errors settings per `shikigami-core.cabal` common stanza apply).

Create the test module `shikigami-core/test/Shikigami/RetrySemanticsSpec.hs` exporting `tests :: TestTree`, add `Shikigami.RetrySemanticsSpec` to the `other-modules` of the `test-suite shikigami-core-test` stanza in `shikigami-core/shikigami-core.cabal` (alongside `Shikigami.AgentWorkflowSpec`), add `async` to the test suite's and library's `build-depends` if missing, and register `RetrySemanticsSpec.tests` in the `testGroup "shikigami"` list in `shikigami-core/test/Main.hs`.

Run the suite:

```bash
nix develop -c cabal test shikigami-core-test --test-show-details=streaming
```

Expected transcript excerpt once complete:

```text
RetrySemantics
  transient behavior failure re-executes on redelivery:            OK
  permanent behavior failure replays without re-execution:         OK
  classifyOutcome maps outcomes to ack decisions:                  OK
  retry delay grows with attempt and caps at 60s:                  OK
  visibility extension prevents redelivery of an in-flight message: OK
  run exceeding its wall-clock budget yields a retry decision:     OK
```

Finally run the full suite to catch regressions in `AgentWorkflowSpec` (its crash-resume tests exercise the same step machinery):

```bash
nix develop -c cabal test all
```


## Validation and Acceptance

Acceptance is behavioral, verified by tests that fail before the change and pass after, written in `shikigami-core/test/Shikigami/RetrySemanticsSpec.hs` using `withShikigamiMigratedDatabase` and the `AgentRunHooks` seam exactly as `Shikigami.AgentWorkflowSpec` does.

Transient re-execution (fails before): build `AgentRunDeps` whose hooks' `beforeStepBody` throws `TransientBehaviorFailure "simulated 503"` on the first entry into `"run-behavior"` (IORef-latched, as in AgentWorkflowSpec.hs:73-82). Call `runAgentRunWorkflow deps job`; assert it throws. Call it again with the same job (same `WorkflowId`); assert `Right (Completed (Right _))` and that the step-body counter for `"run-behavior"` is 2 — the body re-ran. Before this plan the equivalent scenario (a behavior returning `Left`) yields `Completed (Left _)` on both calls with the body having run once. Also drive the real classification path: an agent whose behavior is `ShikumiProgram { task = "nonexistent" }` produces `UnknownTask` → `Permanent` → journaled `Left`; assert two consecutive runs return the same `Completed (Left _)` and the body ran once (replay, correct for permanent).

Ack classification (pure): a table-driven test over `classifyOutcome`: `Completed (Left "unknown agent x")` → `AckDeadLetter`; `Completed (Right …)` → `AckOk`; `Suspended` → `AckOk`; `Failed` → `AckRetry`; and `retryDelayFor` proves the one-based first/second/third-delivery schedule from `mkRetryPolicy`, including its cap and `Nothing` normalization.

Heartbeat primitive: against the migrated database's pgmq schema, create a queue, send a message, read it with a 2-second visibility timeout, extend visibility by 30 seconds (the same `set_vt`-based operation the adapter's lease uses — `Pgmq` session API from `pgmq-hasql`), sleep 3 seconds, and assert a second read returns no message (it would be redelivered without the extension — that variant is the fails-before half of the pair).

Run timeout: hooks whose `beforeStepBody` sleeps 3 seconds inside `"run-behavior"` on first execution only; `runTimeout = Just 1`. Assert the handler-level wrapper returns an `AckRetry` decision, and a second invocation (no sleep) completes with `AckOk`. Structure the timeout wrapper so this is testable without a live queue (export the function that wraps one workflow execution with the timeout).

Beyond tests, observe end-to-end: start the stack (`process-compose.yaml` provides Postgres/Kafka; `just create-database` migrates), run the worker against `agents/`, and enqueue a run for an agent whose behavior takes ~90 seconds. Expected worker stderr: no `JournalAppendConflict`, no duplicate `agent.run` span for one idempotency key, one `workflow completed` line. Kill the worker mid-run and restart: the job is redelivered within ~30 seconds and resumes from the journal.


## Idempotence and Recovery

Every edit is additive or a local rewrite; re-running builds and tests is safe. The new DLQ queue creation is idempotent (pgmq `create` is create-if-not-exists). Rollback of any milestone is a revert of its commits — no migrations and no journal-format changes are involved, so already-journaled workflows are unaffected in both directions. The one behavioral ratchet to be aware of when reverting Milestone 1: runs journaled after the change contain no `run-behavior` entry for attempts that failed transiently (nothing was journaled), which replays identically under old code. If a test database gets into a confusing state, `withShikigamiMigratedDatabase` provisions a fresh database per test, so there is no shared state to clean.


## Interfaces and Dependencies

Hard dependencies: plans 36 and 37. The worker lives in the package assigned by plan
36 and receives validated timeout/retry settings from plan 37's Settei composition root.

Libraries and why: keiro (`Keiro.Workflow` — `step`, `runWorkflow`, `WorkflowOutcome (..)`, `WorkflowError (..)`; journaling semantics this plan leans on), shibuya-core (`Shibuya.Core.Ack` — `AckDecision (..)`, `RetryDelay (..)`, `DeadLetterReason (..)`; `Shibuya.Core.Ingested` — `Ingested (..)` including `lease`; `Shibuya.Core.Lease` — `Lease (..)`; `Shibuya.Core.Types` — `Envelope (..)` including `attempt :: Maybe Attempt`), shibuya-pgmq-adapter (`Shibuya.Adapter.Pgmq.Config` — `defaultConfig`, `PgmqAdapterConfig (..)`, `DeadLetterConfig (..)`, `DeadLetterTarget (..)`), pgmq-hasql (queue creation for the DLQ; visibility-extension session for the heartbeat test), `async` (`Control.Concurrent.Async.withAsync`), `base` (`System.Timeout.timeout`), effectful (`Effectful.withEffToIO`, `UnliftStrategy (ConcUnlift …)`).

Signatures that must exist at the end (full module paths):

```haskell
-- shikigami-core/src/Shikigami/Behavior/Error.hs
data Shikigami.Behavior.Error.FailureClass = Transient | Permanent
Shikigami.Behavior.Error.classifyRunError :: RunError -> FailureClass
newtype Shikigami.Behavior.Error.TransientBehaviorFailure = TransientBehaviorFailure Text
-- instance Exception TransientBehaviorFailure

-- shikigami-core/src/Shikigami/Worker.hs
Shikigami.Worker.classifyOutcome ::
  Maybe Attempt -> Either StoreError (WorkflowOutcome (Either Text AgentRunResult)) -> AckDecision
Shikigami.Worker.retryDelayFor :: Maybe Attempt -> RetryDelay
Shikigami.Worker.handleRunJob :: WorkerEnv -> Maybe Attempt -> Value -> IO AckDecision
-- WorkerEnv gains: runTimeout :: !(Maybe NominalDiffTime), approvalDeadline :: !(Maybe NominalDiffTime)

-- shikigami-core/src/Shikigami/Trigger/Enqueue.hs
Shikigami.Trigger.Enqueue.runDeadLetterQueueName :: QueueName
```

Verified upstream signatures relied upon: keiro `Keiro.Workflow.step :: (Workflow :> es, ToJSON a, FromJSON a) => StepName -> Eff es a -> Eff es a` (journals only on successful return); shibuya `type Shibuya.Handler.Handler es msg = Ingested es msg -> Eff es AckDecision` (pinned tag) with `Ingested { envelope :: Envelope msg, ack :: AckHandle es, lease :: Maybe (Lease es) }`; `Shibuya.Core.Lease.Lease { leaseId :: Text, leaseExtend :: NominalDiffTime -> Eff es () }`; pgmq adapter `AckRetry (RetryDelay delay)` implemented as a relative `set_vt` (redelivery after `delay`), auto-dead-letter at `readCount > maxRetries`. Integration points with sibling plans: docs/plans/20 hard-depends on this plan and consumes `classifyOutcome` for its routing failures; docs/plans/18 shares `Shikigami/Trigger/Enqueue.hs` (queue-name constants and startup queue creation).


## Revision Notes

- 2026-07-22: Recorded plan 20 as a hard downstream consumer of this plan's ack
  classification, eliminating its conditional ad-hoc routing decision.
- 2026-07-22: Corrected attempts to PGMQ's one-based semantics, adopted the shared
  `mkRetryPolicy`, made acknowledgement framework-owned, and moved timeout/deadline
  configuration to Settei.
