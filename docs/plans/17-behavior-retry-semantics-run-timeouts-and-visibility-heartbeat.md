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

- [ ] **M0 (gate, added 2026-08-10): `shibuya-core 0.9.0.0` is in the cohort.** This plan should
      not start before it. 0.9 ships the application-defined dead-letter code vocabulary that
      Milestone 2 would otherwise hand-roll and then delete. It is currently excluded by
      `keiro 0.11`'s `shibuya-core >=0.8.0.1 && <0.9`, so the gate is really `keiro 0.12` →
      cohort bump → this plan. See Surprises & Discoveries and
      `docs/plans/53-upgrade-shikigami-to-the-keiro-0-11-and-keiki-0-9-cohort.md`.
- [ ] Milestone 1: add `FailureClass`/`classifyRunError`/`TransientBehaviorFailure` to `Shikigami.Behavior.Error`; throw transients in `runBehaviorStep`.
- [ ] Milestone 1: tests — transient failure re-executes on second run; permanent failure replays without re-execution.
- [ ] Prerequisites: plans 36/37 complete; worker ownership and Settei configuration are settled.
- [ ] Milestone 2: extract pure `classifyOutcome`; preserve Shibuya as sole ack owner; consume the adapter's zero-based attempt and use the shared `mkRetryPolicy`; configure a real dead-letter queue.
- [ ] Milestone 2: validate shikigami's finite dead-letter code set **once at worker startup**
      with `mkDeadLetterCode`, hold the results in `WorkerEnv`, and classify permanent failures
      as `ApplicationFailure` rather than `PoisonPill`. Do not validate per message.
- [ ] Milestone 2: tests — classification table test asserting `deadLetterReasonCode` for each
      case; dead-letter queue receives permanent failures with populated
      `dead_letter_reason_code` and `dead_letter_reason_detail` fields.
- [ ] Milestone 3: thread the shibuya lease into `handleRunJob`; periodic heartbeat around the workflow execution.
- [ ] Milestone 3: test — pgmq visibility-extension primitive prevents redelivery.
- [ ] Milestone 4: wall-clock run timeout (`runTimeout`) and configurable approval `deadline` in `WorkerEnv`; Settei wiring.
- [ ] Milestone 4: test — a run exceeding the budget yields a retry decision and completes on the next attempt.
- [ ] Register `Shikigami.RetrySemanticsSpec` in `shikigami-core.cabal` and `shikigami-core/test/Main.hs`; `cabal build all` and `cabal test all` green under `nix develop`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**Shibuya shipped this plan's dead-letter vocabulary on 2026-08-10 (discovered same day).**
`shibuya-core 0.9.0.0` extends `DeadLetterReason` with a fourth constructor:

```haskell
data DeadLetterReason
  = PoisonPill !Text
  | InvalidPayload !Text
  | MaxRetriesExceeded
  | ApplicationFailure !DeadLetterCode !Text
```

`DeadLetterCode` is an opaque newtype whose constructor is private; values come from
`mkDeadLetterCode :: Text -> Either Text DeadLetterCode`, which accepts at most 128 ASCII
characters in at least two dot-separated segments, each segment matching `[a-z][a-z0-9_]*`, with
the first segment `shibuya` reserved for framework codes. Alongside it, 0.9 adds the total
projections `deadLetterReasonCode :: DeadLetterReason -> DeadLetterCode` and
`deadLetterReasonDetail :: DeadLetterReason -> Maybe Text`, the canonical renderer
`renderDeadLetterReason`, and the built-in codes `poisonPillCode`, `invalidPayloadCode`, and
`maxRetriesExceededCode`. Processing spans now carry the stable code as
`shibuya.dead_letter.reason.code`, keeping human detail out of attributes and metrics.
`shibuya-pgmq-adapter 0.14.0.0` carries it into the DLQ payload: every message keeps the
compatibility field `dead_letter_reason` and gains `dead_letter_reason_code` plus an
always-present `dead_letter_reason_detail`.

**Why this matters more than a version bump.** As written, Milestone 2 classifies every permanent
failure as `AckDeadLetter (PoisonPill err)` — one bucket, with the actual reason smuggled into a
free-text string that operators would have to grep. Milestone 2 also intends a table-driven
classification test, which is a taxonomy in all but name. Building that taxonomy privately on
0.8 and then meeting 0.9 means writing a code type, a renderer, and a projection and deleting all
three. The upstream `DeadLetterCode` is also stricter than a hand-rolled string would have been —
private constructor, validated shape, reserved namespace, validate-at-startup discipline — and
that strictness is the point.

**The gate is indirect, which is easy to miss.** `shibuya-core 0.9.0.0` is published, but
`keiro 0.11.0.0` declares `shibuya-core >=0.8.0.1 && <0.9` in `keiro/keiro.cabal`, so the cohort
cannot take it yet. The release that lifts the cap is `keiro 0.12`, already staged in keiro's
`Unreleased` section. `shibuya-pgmq-adapter 0.14.0.0` follows shibuya-core 0.9 and is excluded
the same way, which is why plan 53 takes `0.13.0.0`. So the real chain is: keiro 0.12 publishes →
a cohort bump takes shibuya-core 0.9 and adapter 0.14 → this plan starts.

**If the gate does not clear in a reasonable time**, implement Milestone 2 against 0.8 but keep
every permanent-failure classification behind one module that returns a shikigami-owned code
type, with `PoisonPill (renderMyCode c <> ": " <> detail)` as the only place the two are flattened
together. The 0.9 swap is then deleting that flattening and changing one constructor. Do not
scatter `PoisonPill` construction across `classifyOutcome`'s arms.


## Decision Log

Record every decision made while working on the plan.

- Decision: Express transient failures by throwing `TransientBehaviorFailure` from inside the step body instead of journaling a `Left`, rather than rotating a retry generation into the step name or adding a retry wrapper.
  Rationale: Verified keiro semantics (keiro `src/Keiro/Workflow.hs`, `Step` handler: the journal append happens only after the step body returns a value; a thrown exception propagates un-journaled, so the step re-runs on the next execution). This is keiro's documented contract — "step side effects are at-least-once; bodies must be idempotent" — and needs no new framework features. Step-name rotation would violate the additive-only journal discipline of docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md.
  Date: 2026-07-08

- Decision: Keep `agentRunWorkflow`'s result type `Either Text AgentRunResult` unchanged; after this plan a journaled `Left` means "permanent failure" by construction, and the worker dead-letters all `Completed (Left _)` outcomes.
  Rationale: Keeping it deletes the `"unknown agent "` string-prefix hack for free: unknown-agent is just another permanent `Left`. (The original rationale also cited the JSON encoding of already-completed workflows, which no longer applies — shikigami has no users and no completed workflow is stored anywhere. The decision stands on the simplification alone.)
  Date: 2026-07-08, rationale narrowed 2026-08-10

- Decision: Classify permanent failures as `ApplicationFailure` with a validated, shikigami-owned
  `DeadLetterCode`, not as `PoisonPill` carrying free text.
  Rationale: this plan was already going to build a permanent-failure taxonomy — Milestone 2's
  table-driven classification test is that taxonomy — and `shibuya-core 0.9.0.0` ships the typed
  vocabulary for it, with a validated code shape, a reserved framework namespace, total
  projections, and transport of the code through the adapter into the DLQ payload as a
  machine-queryable `dead_letter_reason_code`. `PoisonPill` flattens every permanent failure into
  one bucket whose reason survives only as prose, which makes the DLQ greppable rather than
  queryable. Building the taxonomy privately and meeting 0.9 later means writing a code type, a
  renderer, and a projection and then deleting all three.
  Date: 2026-08-10

- Decision: Validate the dead-letter code set once at worker startup and hold the values in
  `WorkerEnv`, rather than calling `mkDeadLetterCode` per message.
  Rationale: `mkDeadLetterCode` returns `Either Text DeadLetterCode`, and shibuya's own haddock
  directs callers to validate a finite set during application startup and reuse the results.
  Per-message validation would put a partial function on the hot path and force every
  classification site to handle a failure that is really a programming error. A malformed code
  should stop the worker from starting, not degrade one message.
  Date: 2026-08-10

- Decision: Use the code set `shikigami.unknown_agent`, `shikigami.unsupported_behavior`,
  `shikigami.skill_load_failed`, `shikigami.behavior_failed`, and `shikigami.run_cancelled`.
  Rationale: each satisfies `mkDeadLetterCode`'s shape (two segments, `[a-z][a-z0-9_]*`, first
  segment not `shibuya`), and the set is the permanent half of the `RunError` classification this
  plan already decided on — `UnknownTask`, `UnsupportedBehavior`, and `SkillLoadFailed` map one
  to one, `behavior_failed` covers a permanent `Left` from any other source, and `run_cancelled`
  replaces the `PoisonPill` currently produced for `Cancelled` at `Worker.hs:190`. Keeping the set
  finite and startup-validated is what makes it a taxonomy rather than a string convention. Detail
  text is transported verbatim to operators, so it must stay bounded and must not carry secrets,
  raw payloads, raw SQL, or unrestricted backend errors — shibuya's haddock is explicit about
  this and it is now shikigami's obligation.
  Date: 2026-08-10

- Decision: Keep the PGMQ visibility timeout at 30 seconds and add a lease heartbeat, rather than raising the visibility timeout to cover the longest imaginable run.
  Rationale: A large static timeout delays redelivery after a genuine worker crash by the full window; a heartbeat keeps crash-recovery latency at about 30 seconds while protecting arbitrarily long healthy runs. Shibuya 0.8 exposes `lease :: Maybe (Lease es)` on the handler's public `Message es msg`, and shibuya-pgmq-adapter 0.12 implements it with PGMQ `set_vt`.
  Date: 2026-07-08

- Decision: Classify `RunError` conservatively: `UnknownTask`, `SkillLoadFailed`, `UnsupportedBehavior` are permanent; `ProgramFailed`, `SkillRunFailed` are transient.
  Rationale: The permanent three are configuration errors that no retry can fix. The transient two wrap provider/tool execution and are where flaky LLM/HTTP failures surface; misclassifying a truly-permanent program bug as transient costs bounded retries (maxRetries=3) and then a dead-letter, which is inspectable — the safe failure mode.
  Date: 2026-07-08

- Decision: On run timeout, return a retry decision (not dead-letter).
  Rationale: The journal preserves all completed steps, so the retry resumes from the last journaled step rather than restarting; a slow run frequently completes within a second budget. Repeated timeouts exhaust `maxRetries` and land in the dead-letter queue anyway.
  Date: 2026-07-08
- Decision: Treat `Envelope.attempt` as zero-based and build delays/ceilings with the shared
  `mkRetryPolicy`; do not normalize it again in Shikigami.
  Rationale: shibuya-pgmq-adapter 0.12 already maps PGMQ's one-based `read_count` through
  `Attempt (max 0 (readCount - 1))`. Subtracting again would make the first two deliveries
  indistinguishable and shift retry ceilings.
  Date: 2026-07-30
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

with this mapping: `Left storeErr` → `AckRetry (retryDelayFor attempt)` (transient infrastructure); `Right (Completed (Right _))` → `AckOk`; `Right (Completed (Left err))` → `AckDeadLetter (ApplicationFailure code detail)` (permanent by Milestone 1's construction — this deletes the `"unknown agent "` prefix match at Worker.hs:184-185); `Right Suspended` → `AckOk`; `Right ContinuedAsNew` → `AckOk`; `Right Cancelled` → `AckDeadLetter (ApplicationFailure shikigamiRunCancelled …)` (replacing the `PoisonPill` at Worker.hs:190); `Right Failed` → `AckRetry (retryDelayFor attempt)`.

The `code` in the permanent case comes from the startup-validated set held in `WorkerEnv`, chosen
from the `FailureClass` Milestone 1 attaches to the failure rather than re-derived from the error
text: `UnknownTask` → `shikigami.unknown_agent`, `UnsupportedBehavior` →
`shikigami.unsupported_behavior`, `SkillLoadFailed` → `shikigami.skill_load_failed`, and anything
else permanent → `shikigami.behavior_failed`. `classifyOutcome` stays pure by taking the
validated codes as an argument rather than reaching for a global. `detail` is the existing error
text, bounded — shibuya transports it verbatim to operators, so it must not carry secrets, raw
payloads, raw SQL, or unrestricted backend error text. Treat `Envelope.attempt = Just (Attempt 0)` as the first delivery and `Nothing` as zero for adapters without attempt metadata. Derive `retryDelayFor` from the shared `mkRetryPolicy` with an explicit cap. Do not duplicate exponential arithmetic in the worker. In `runOneAgent`, catch typed transient/framework errors and return the one `AckDecision` Shibuya will finalize; do not manipulate the queue directly. `runConversationAgent` uses the same policy.

Configure the adapter with a DLQ: in `runQueueWorker` (Worker.hs:76), replace `defaultConfig runQueueName` with

```haskell
(defaultConfig runQueueName)
  { deadLetterConfig =
      Just DeadLetterConfig { dlqTarget = DirectQueue runDeadLetterQueueName, includeMetadata = True }
  }
```

where `runDeadLetterQueueName` parses `"shikigami_run_jobs_dlq"` (add it next to `runQueueName` in `shikigami-core/src/Shikigami/Trigger/Enqueue.hs`, and ensure the queue exists at worker startup with pgmq `createQueue` — coordinate with docs/plans/18, which introduces `ensureRunQueue`; and with docs/plans/20, which hardens this module). `DeadLetterConfig`/`DeadLetterTarget` come from `Shibuya.Adapter.Pgmq.Config`. With this set, both explicit `AckDeadLetter` decisions and `MaxRetriesExceeded` auto-dead-letters are moved to the DLQ transactionally instead of archived silently.

Milestone 3 — visibility heartbeat. Scope: `shikigami-core/src/Shikigami/Worker.hs`. At the end, a handler extends its message lease every 10 seconds for as long as the run executes, so a 5-minute LLM call is never redelivered mid-flight.

Change `runJobHandler` to keep the whole public `Message` value: Shibuya 0.8 defines
`type Handler es msg = Message es msg -> Eff es AckDecision` and
`Message { envelope, lease }`, deliberately omitting the framework-owned acknowledgement
handle. Because `leaseExtend :: NominalDiffTime -> Eff es ()` lives in the handler's effect row
but the heartbeat must tick concurrently with the IO orchestration, obtain an IO unlift with
effectful's concurrent unlift — `withEffToIO (ConcUnlift Persistent (Limited 1))` from
`Effectful` — and race the heartbeat against the work:

```haskell
runJobHandler env message@Message {envelope = Envelope {payload = p, attempt}} =
  withEffToIO (ConcUnlift Persistent (Limited 1)) \unlift ->
    withAsync (heartbeat unlift (lease message)) \_ ->
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

Ack classification (pure): a table-driven test over `classifyOutcome`: `Completed (Left "unknown agent x")` → `AckDeadLetter`; `Completed (Right …)` → `AckOk`; `Suspended` → `AckOk`; `Failed` → `AckRetry`; and `retryDelayFor` proves the zero-based first/second/third-delivery schedule from `mkRetryPolicy`, including its cap and `Nothing` normalization. Each dead-letter row additionally asserts the expected code through `deadLetterReasonCode`, so the taxonomy is pinned by test rather than by convention — this is the assertion that makes the code set a contract. A separate test asserts that every code in the startup set survives `mkDeadLetterCode`, which turns a typo into a failing test rather than a worker that will not boot.

Heartbeat primitive: against the migrated database's pgmq schema, create a queue, send a message, read it with a 2-second visibility timeout, extend visibility by 30 seconds (the same `set_vt`-based operation the adapter's lease uses — `Pgmq` session API from `pgmq-hasql`), sleep 3 seconds, and assert a second read returns no message (it would be redelivered without the extension — that variant is the fails-before half of the pair).

Run timeout: hooks whose `beforeStepBody` sleeps 3 seconds inside `"run-behavior"` on first execution only; `runTimeout = Just 1`. Assert the handler-level wrapper returns an `AckRetry` decision, and a second invocation (no sleep) completes with `AckOk`. Structure the timeout wrapper so this is testable without a live queue (export the function that wraps one workflow execution with the timeout).

Beyond tests, observe end-to-end: start the stack (`process-compose.yaml` provides Postgres/Kafka; `just create-database` migrates), run the worker against `agents/`, and enqueue a run for an agent whose behavior takes ~90 seconds. Expected worker stderr: no `JournalAppendConflict`, no duplicate `agent.run` span for one idempotency key, one `workflow completed` line. Kill the worker mid-run and restart: the job is redelivered within ~30 seconds and resumes from the journal.


## Idempotence and Recovery

Every edit is additive or a local rewrite; re-running builds and tests is safe. The new DLQ queue creation is idempotent (pgmq `create` is create-if-not-exists). Rollback of any milestone is a revert of its commits — no migrations and no journal-format changes are involved, so already-journaled workflows are unaffected in both directions. The one behavioral ratchet to be aware of when reverting Milestone 1: runs journaled after the change contain no `run-behavior` entry for attempts that failed transiently (nothing was journaled), which replays identically under old code. If a test database gets into a confusing state, `withShikigamiMigratedDatabase` provisions a fresh database per test, so there is no shared state to clean.


## Portfolio Reconciliation (2026-07-30, amended 2026-08-10)

This plan hard-depends on plans 36, 37, and 47. Shibuya 0.8 handlers receive public
`Message es msg` values containing `envelope` and optional `lease` and return one
`AckDecision`; never retain the old `Ingested`/ack-handle API. The current PGMQ adapter
already maps one-based `read_count` to zero-based `Envelope.attempt`, so attempt zero is
first delivery and Shikigami must not subtract again. Use `AppConfig` and `OrderingPolicy`
from the released Shibuya surface.

Amended 2026-08-10: this plan now also depends on
`docs/plans/53-upgrade-shikigami-to-the-keiro-0-11-and-keiki-0-9-cohort.md` and on the cohort
bump that follows `keiro 0.12`, because Milestone 2's dead-letter taxonomy should be built on
`shibuya-core 0.9.0.0`'s `ApplicationFailure`/`DeadLetterCode` rather than hand-rolled on 0.8.
Plan 53 deliberately holds `shibuya-core` at `0.8.0.1` and `shibuya-pgmq-adapter` at `0.13.0.0`
because keiro 0.11 caps them; it also records the request for `keiro 0.12` that lifts the cap.
Everything above about the 0.8 handler shape and zero-based attempts remains true at 0.9 — that
release adds a `DeadLetterReason` constructor and total projections and changes nothing else this
plan touches.


## Interfaces and Dependencies

Hard dependencies: plans 36, 37, and 47. The worker lives in the package assigned by plan
36, receives validated timeout/retry settings from plan 37's Settei composition root, and
targets the coherent released Shibuya/PGMQ cohort from plan 47.

Libraries and why: keiro (`Keiro.Workflow` — `step`, `runWorkflow`, `WorkflowOutcome (..)`, `WorkflowError (..)`; journaling semantics this plan leans on), shibuya-core (`Shibuya.Core.Ack` — `AckDecision (..)`, `RetryDelay (..)`, `DeadLetterReason (..)`; `Shibuya.Core.Ingested` — public `Message (..)` including `lease`; `Shibuya.Core.Lease` — `Lease (..)`; `Shibuya.Core.Types` — `Envelope (..)` including zero-based `attempt :: Maybe Attempt`), shibuya-pgmq-adapter (`Shibuya.Adapter.Pgmq.Config` — `defaultConfig`, `PgmqAdapterConfig (..)`, `DeadLetterConfig (..)`, `DeadLetterTarget (..)`), pgmq-hasql (queue creation for the DLQ; visibility-extension session for the heartbeat test), `async` (`Control.Concurrent.Async.withAsync`), `base` (`System.Timeout.timeout`), effectful (`Effectful.withEffToIO`, `UnliftStrategy (ConcUnlift …)`).

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

Verified upstream signatures relied upon: keiro `Keiro.Workflow.step :: (Workflow :> es, ToJSON a, FromJSON a) => StepName -> Eff es a -> Eff es a` (journals only on successful return); Shibuya 0.8 `type Shibuya.Handler.Handler es msg = Message es msg -> Eff es AckDecision` with `Message { envelope :: Envelope msg, lease :: Maybe (Lease es) }`; `Shibuya.Core.Lease.Lease { leaseId :: Text, leaseExtend :: NominalDiffTime -> Eff es () }`; shibuya-pgmq-adapter 0.12 exposes zero-based attempts and implements `AckRetry (RetryDelay delay)` as a relative `set_vt`, with auto-dead-letter after the configured retry ceiling.

Added by shibuya-core `0.9.0.0`, and required by this plan's Milestone 2 (verified against
`shibuya-core/src/Shibuya/Core/Ack.hs` at tag `v0.9.0.0` on 2026-08-10):
`DeadLetterReason` gains `ApplicationFailure !DeadLetterCode !Text`;
`mkDeadLetterCode :: Text -> Either Text DeadLetterCode` is the only way to make a code;
`deadLetterCodeText :: DeadLetterCode -> Text`,
`deadLetterReasonCode :: DeadLetterReason -> DeadLetterCode`,
`deadLetterReasonDetail :: DeadLetterReason -> Maybe Text`, and
`renderDeadLetterReason :: DeadLetterReason -> Text` are total; `poisonPillCode`,
`invalidPayloadCode`, and `maxRetriesExceededCode` name the built-ins. `shibuya-metrics 0.9.0.0`
releases in lockstep with an updated bound and no API change. `shibuya-pgmq-adapter 0.14.0.0`
requires `shibuya-core ^>=0.9.0.0` and writes `dead_letter_reason_code` and
`dead_letter_reason_detail` into the DLQ payload alongside the retained `dead_letter_reason`.

Because `DeadLetterReason` gains a constructor, any exhaustive match over it must be extended.
In this repository that is one import site today —
`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs:35` imports `DeadLetterReason (..)` — and
the total projections exist precisely so downstream code can avoid matching exhaustively at all. Integration points with sibling plans: docs/plans/20 hard-depends on this plan and consumes `classifyOutcome` for its routing failures; docs/plans/18 shares `Shikigami/Trigger/Enqueue.hs` (queue-name constants and startup queue creation).


## Revision Notes

- 2026-07-22: Recorded plan 20 as a hard downstream consumer of this plan's ack
  classification, eliminating its conditional ad-hoc routing decision.
- 2026-07-30: Corrected the released adapter contract: `Message` replaces handler-facing
  `Ingested`, acknowledgement remains framework-owned, and `Envelope.attempt` is already
  zero-based after the adapter converts PGMQ `read_count`.
- 2026-08-10: Re-pointed Milestone 2's dead-letter handling at `shibuya-core 0.9.0.0`, and added
  a gate so this plan does not start before that release is in the cohort.

  The reason is rework, and it is the largest instance of it in the portfolio. Milestone 2 was
  going to classify every permanent failure as `AckDeadLetter (PoisonPill err)` — one bucket with
  the real reason as prose — while also building a table-driven classification test, which is a
  permanent-failure taxonomy in all but name. Shibuya 0.9 ships exactly that taxonomy as typed
  vocabulary: `ApplicationFailure !DeadLetterCode !Text`, an opaque code validated by
  `mkDeadLetterCode`, total `deadLetterReasonCode`/`deadLetterReasonDetail` projections, a
  canonical renderer, a reserved `shibuya` namespace, and adapter transport of the code into the
  DLQ payload as a queryable `dead_letter_reason_code`. Implementing on 0.8 first means writing a
  code type, a renderer, and a projection and then deleting all three.

  Concretely: Progress gained an M0 gate and two Milestone 2 items (startup validation, and
  code-asserting tests); Surprises & Discoveries records the 0.9 API with its validation rules and
  explains that the gate is indirect — `keiro 0.11` caps `shibuya-core <0.9`, so the chain is
  keiro 0.12 → cohort bump → this plan; the Decision Log gained three entries covering the
  constructor choice, startup-only validation, and the concrete five-code set
  (`shikigami.unknown_agent`, `shikigami.unsupported_behavior`, `shikigami.skill_load_failed`,
  `shikigami.behavior_failed`, `shikigami.run_cancelled`); the Milestone 2 mapping now names
  `ApplicationFailure` and says how the code is chosen from Milestone 1's `FailureClass` rather
  than re-derived from error text; Validation asserts codes through `deadLetterReasonCode` and
  proves the whole set passes `mkDeadLetterCode`; and Interfaces records the exact 0.9 surface
  with the note that `DeadLetterReason` gaining a constructor breaks exhaustive matches, of which
  this repository has one.

  Surprises & Discoveries also records the fallback if the gate does not clear soon: implement on
  0.8, but keep every permanent classification behind one module returning a shikigami-owned code
  type, flattened to `PoisonPill` in exactly one place, so the 0.9 swap is a one-constructor
  change.

  One older rationale was narrowed rather than removed. The decision to keep
  `agentRunWorkflow`'s `Either Text AgentRunResult` result type cited the JSON encoding of
  already-completed workflows; shikigami has no users and no stored completed workflow, so that
  argument is void. The decision stands on its other ground — it deletes the `"unknown agent "`
  string-prefix hack.
