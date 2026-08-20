---
id: 18
slug: atomic-stream-consumption-offsets-inbox-and-enqueue-in-one-boundary
title: "Atomic stream consumption: offsets, inbox, and enqueue in one boundary"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tykwvek587vr2gwtcf81j"
master_plan: "docs/masterplans/3-correctness-and-delivery-semantics-stop-dropping-and-duplicating-work.md"
---

# Atomic stream consumption: offsets, inbox, and enqueue in one boundary

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami's stream triggers turn Kafka events into agent runs. Today that pipeline can silently lose an event forever in two distinct ways: the consumer commits the Kafka offset even when processing failed (so a transient Postgres outage permanently skips every event that arrived during it), and the run-job enqueue happens outside the database transaction that marks the event as processed (so a crash in the gap leaves the event marked "done" with no run ever enqueued — and the deduplicating inbox guarantees it is never retried). A third gap makes the whole consumer fragile: any Kafka error terminates the subscribe loop with a single stderr line, and the process stops consuming until someone restarts it.

After this plan, "the inbox accepted the event" and "the run job is on the queue" are one atomic fact — they commit in the same Postgres transaction — and the Kafka offset is committed only after an explicit durable terminal disposition: enqueued, duplicate, or permanently dead-lettered. Transient failures leave the offset uncommitted so the event is redelivered. Undecodable/poison records are written to a durable dead-letter target (or halt the partition if that write fails), never merely logged and discarded. Consumption is serial and acknowledgement/offset commit remains framework-owned.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-20T00:35:42Z) Milestone 1: added `enqueueRunJobTx` and `ensureRunQueue` in `Shikigami.Trigger.Enqueue`; both activity and integration-event handlers now enqueue inside the inbox transaction, and the composition callbacks are logging-only.
- [x] (2026-08-20T00:35:42Z) Milestone 1 tests: real-Postgres atomic success, forced queue-send rollback, and duplicate delivery all pass in `Shikigami.StreamInboxSpec`.
- [x] (2026-08-20T00:25:35Z) Prerequisites reconciled: plan 36 moved the consumer to `shikigami-workers`; plan 37 settled both consumer roles' Settei Kafka settings (its only remaining migration-CLI item is unrelated); plan 47's dependency cohort has since been superseded by the released Keiro 0.13 / Shibuya 0.9 / PGMQ 0.5 cohort already selected by `cabal.project`.
- [x] (2026-08-20T00:56:21Z) Milestone 2: `RecordDisposition` covers enqueued, duplicate, permanent-dead-letter, and transient failure; `ackDecisionFor` authorizes terminal acknowledgement only for the first three.
- [x] (2026-08-20T00:56:21Z) Milestone 2 tests: store/send failures leave no inbox row, `TransientFailure` becomes `AckHalt`, and terminal dispositions each map to one framework ack decision.
- [x] (2026-08-20T00:56:21Z) Milestone 3: both subscriptions now use Shibuya Kafka adapter 0.9 with `StrictInOrder`/`Serial`, no application-side commit call, capped 1/2/4/…/30-second reconnect delay, and typed programming-failure escape.
- [x] (2026-08-20T00:56:21Z) Milestone 3 poison path: malformed records persist bounded evidence and delivery coordinates to the configured PGMQ queue before `AckDeadLetter`; failed persistence becomes `AckHalt`.
- [x] (2026-08-20T00:35:42Z) Consumer composition updates: `consume-stream`/`consume-events` `onHit` is logging-only and each startup calls `ensureRunQueue` before subscribing.
- [x] (2026-08-20T00:35:42Z) Registered `Shikigami.StreamInboxSpec` in the worker test suite; `nix develop -c cabal build all` passes and all 27 worker tests pass after Milestone 1.
- [ ] Final validation: `StreamInboxSpec` now covers disposition/ack, unavailable store, durable poison-DLQ, and failed-DLQ behavior (31 worker tests pass); run `cabal test all` and the feasible manual resilience checks.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The plan's July source locations and dependency snapshot are stale after plans 36, 37,
  and later cohort upgrades. The live consumer is
  `shikigami-workers/src/Shikigami/Trigger/Consumer.hs`; Hackage and upstream tags both
  identify Keiro 0.13.0.0, Shibuya core 0.9.0.0, Shibuya Kafka adapter 0.9.0.0, and
  PGMQ 0.5.0.0 as the current releases on 2026-08-19.
  Evidence: `cabal.project`, `mori registry show`, Hackage `preferred.json`, and upstream
  `git ls-remote --tags` agree on those versions.

- Shibuya Kafka adapter 0.9.0.0 preserves the raw `Maybe ByteString` payload and owns
  offset storage, seek-on-retry, partition pause, and consumer serialization, but its
  documentation explicitly says it has no DLQ producer. `AckDeadLetter` alone would
  therefore commit over and drop a poison record. Shikigami must persist its own durable
  dead-letter evidence before returning a terminal disposition.
  Evidence: `Shibuya.Adapter.Kafka.kafkaAdapter` returns
  `Adapter es (Maybe ByteString)`, and the released adapter README says
  `AckDeadLetter` stores the offset after a warning and does not produce to a DLQ.

- Plan 36 moved the consumer vertical but this plan's test instructions still name the
  core test suite. The worker test suite already depends on `pgmq-hasql` and
  `shikigami-migrations:test-support`, so it is now the package-correct home for the
  broker-free transactional acceptance tests.
  Evidence: `shikigami-workers/shikigami-workers.cabal` exposes
  `Shikigami.Trigger.Consumer` and declares both test dependencies.

- The released Shibuya Kafka adapter does not copy `ConsumerRecord.crKey` into its public
  `Envelope`; it does preserve raw value bytes, headers, partition, and cursor. Shikigami's
  inbox identity and both trigger matchers use the canonical integration headers/payload,
  not `IntegrationEvent.key`, so the adapter can own acknowledgement without changing the
  current trigger result. Evidence: the 0.9.0.0 `consumerRecordToEnvelope` implementation in
  `mori://shinzui/shibuya-kafka-adapter/packages/shibuya-kafka-adapter` and repository-wide
  key-use inspection.

- An unavailable database can raise Kiroku's typed `NotifierStartError` while acquiring the
  store, before `runAppIO` enters its `StoreError` effect. Treating only this typed startup
  exception as transient is necessary for the promised disposition; unrelated synchronous
  exceptions remain programming failures and escape after Shibuya halts without storing the
  offset. Evidence: the unavailable-port acceptance test initially raised
  `NotifierConnectError`, then passed after the typed boundary was added.


## Decision Log

Record every decision made while working on the plan.

- Decision: Achieve atomicity by moving the pgmq send inside the keiro inbox transaction, not by making the enqueue idempotent or by adding a reconciliation sweeper.
  Rationale: The pgmq queue lives in the same Postgres database as the keiro inbox (both reached through the kiroku store pool), and keiro's inbox handler runs inside the transaction with type `IntegrationEvent -> Tx.Transaction a` (verified: keiro `src/Keiro/Inbox.hs`, `attemptOneTx` calls the handler between the inbox insert and commit), while pgmq-hs exposes a `Statement`-level `sendMessage` composable via `Hasql.Transaction.statement`. One transaction is strictly simpler and strictly stronger than compensations.
  Date: 2026-07-08

- Decision: On a transient store error, do not commit the offset and tear down the consumer (outer loop reconnects with backoff), rather than trying to re-seek the partition in place.
  Rationale: After `pollMessage` the client's in-memory position has advanced past the record even without a commit; re-consuming it in-place would require explicit partition seeks. Rebuilding the consumer resumes from the last committed offset, which is exactly the record that failed — correct and simple. The keiro inbox dedupes any records that were already processed before the crash, so over-delivery is harmless.
  Date: 2026-07-08

- Decision: A record is committed only after an explicit durable terminal disposition.
  Undecodable records are stored in a dead-letter target with topic, partition, offset,
  bounded payload evidence, and error; if that write fails, consumption halts without
  committing.
  Rationale: a log line is not recoverable state. This avoids both partition wedging and
  silent data loss while retaining an operator remediation path.
  Date: 2026-07-22
- Decision: Use shibuya's serial processing/acknowledgement boundary; application code
  returns a disposition and never independently commits an offset.
  Rationale: one framework owner preserves record order and prevents double commits or
  a commit racing durable inbox/DLQ state.
  Date: 2026-07-22

- Decision: Build `RunJob`s inside the consumer (via the existing pure builders) instead of keeping the enqueue in the CLI's `onHit` callback.
  Rationale: Atomicity requires the enqueue inside the inbox transaction, which lives in `Shikigami.Trigger.Consumer`; a callback that performs IO cannot run inside a `Tx.Transaction`. `onHit` survives as a logging hook only.
  Date: 2026-07-08

- Decision: Reconcile this plan to the released Shibuya Kafka adapter 0.9.0.0 and run its
  processor as `StrictInOrder` plus `Serial`; do not retain the hand-written
  `pollMessage`/`commitOffsetMessage` loop.
  Rationale: the released adapter preserves raw bytes, seeks on retry, serializes every
  librdkafka operation, and explicitly requires serial processing because librdkafka
  stores only the highest offset per partition. Using the public adapter makes Shibuya the
  single acknowledgement owner required by this plan.
  Date: 2026-08-19

- Decision: Persist undecodable records to a Shikigami-owned PGMQ dead-letter queue in
  the same Postgres database, and create that queue idempotently at consumer startup.
  Rationale: the released Kafka adapter does not produce dead letters, the plan forbids a
  log-and-commit fallback, PGMQ is already migrated and available without a schema change,
  and its returned `MessageId` supplies the required durable `DeadLetterId`. A failed send
  remains transient and cannot authorize an offset commit.
  Date: 2026-08-19

- Decision: Put `Shikigami.StreamInboxSpec` in `shikigami-workers/test`, not
  `shikigami-core/test`.
  Rationale: plan 36 moved `Shikigami.Trigger.Consumer` into the worker package. Keeping
  the test beside its owner preserves the package dependency direction and uses the worker
  suite's existing database/PGMQ test dependencies.
  Date: 2026-08-19

- Decision: Accept the Shibuya Kafka adapter 0.9 public envelope's missing Kafka key for
  this consumer, while preserving every header and payload byte it does expose.
  Rationale: neither activity matching, event matching, Keiro inbox dedupe, nor `RunJob`
  identity consults the reconstructed `IntegrationEvent.key`; retaining a private raw
  librdkafka loop solely for that unused field would give acknowledgement ownership back to
  application code and violate the more important offset-safety invariant. The limitation is
  recorded against `mori://shinzui/shibuya-kafka-adapter` for a future adapter enhancement.
  Date: 2026-08-19

- Decision: Convert only Kiroku's typed `NotifierStartError` and ordinary returned store
  errors to `TransientFailure`; trap any other synchronous handler exception long enough to
  return `AckHalt HaltFatal`, then rethrow it outside Shibuya so the process supervisor sees
  it.
  Rationale: Shibuya intentionally converts a thrown handler exception to retry. Recording
  the exception, halting the partition without offset storage, and rethrowing after processor
  shutdown preserves both requirements: programming failures escape, and their current
  record cannot be committed.
  Date: 2026-08-19


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Milestone 1 complete (2026-08-19). The consumer's success path now has the promised
all-or-nothing Postgres boundary. Against a migrated test database, one matching activity
produces one completed Keiro inbox row and one decodable `RunJob`; replay returns
`Duplicate` and leaves one queue message; dropping the run queue forces the transactional
send to fail, leaves no inbox row, and permits a successful redelivery after queue
reconciliation. The worker suite reports 27 passing tests and `cabal build all` succeeds.

Milestones 2 and 3 complete (2026-08-19). Application code no longer imports a Kafka
offset-commit operation. The Shibuya adapter is the sole acknowledgement owner under
`StrictInOrder` plus `Serial`: enqueued and duplicate records return `AckOk`, a poison
record returns `AckDeadLetter` only after its PGMQ message is durable, and any store or
dead-letter failure returns `AckHalt` so the rebuilt consumer resumes from the last stored
offset. The poison message retains topic/partition/offset, a 2,048-character-bounded error,
and at most 256 payload bytes with full byte count/truncation metadata. All 31 worker tests
pass, including a real unavailable-store probe and both dead-letter outcomes.


## Context and Orientation

Two long-running consumers live in `shikigami-workers/src/Shikigami/Trigger/Consumer.hs`. `subscribeActivityStream` consumes the `activity.v1` Kafka topic: each record is decoded into a keiro `IntegrationEvent`, pushed through the keiro idempotent inbox, matched against the declared stream agents, and reported as `StreamHit` values to an `onHit :: StreamHit -> IO ()` callback. `subscribeIntegrationEventStream` does the same for public integration-event topics (danwa addressed messages), producing `EventHit`s. The inbox handlers build and enqueue `RunJob`s inside their transaction; the composition functions `runConsumeStream` and `runConsumeEvents` in `shikigami-workers/src/Shikigami/Workers/Subscription.hs` now use `onHit` for logging only and reconcile both PGMQ queues before subscribing.

The "keiro idempotent inbox" is a Postgres table (`keiro.keiro_inbox`) plus `runInboxTransaction` (keiro `src/Keiro/Inbox.hs:80-88`, re-exported as `Keiro.Inbox.runInboxTransaction`), which in one Postgres transaction inserts a dedupe row for the event and runs a caller-supplied handler of type `IntegrationEvent -> Tx.Transaction a` — `Tx` being hasql-transaction's `Hasql.Transaction`. If the dedupe row already exists, it returns `InboxDuplicate` without running the handler. Everything the handler writes commits atomically with the dedupe row. Crucially, pgmq is also plain Postgres in the same database: `pgmq-hasql` exposes `Pgmq.Hasql.Statements.Message.sendMessage :: Statement SendMessage MessageId` at the `Statement` level, so a queue send can be composed into the same transaction with `Hasql.Transaction.statement` (the shibuya pgmq adapter already composes pgmq statements into transactions this way).

The three verified pre-plan bugs were:

Unconditional offset commit. Both poll loops commit the offset immediately after processing, regardless of outcome: `liftIO (processRecord …) >> commitOffsetMessage OffsetCommit record` (Consumer.hs:94-96) and identically at Consumer.hs:121-123. `processRecord` (Consumer.hs:127-160) returns `()` and swallows every failure into stderr: decode errors (line 150), inbox errors (line 159), and store errors (line 160 — `Left serr`, e.g. a Postgres connection failure) are all logged and then committed over. A transient database outage therefore permanently skips every event polled during it.

Non-atomic inbox→enqueue. The inbox transaction marks the event processed and returns the hits; only afterwards does `mapM_ onHit hits` run (Consumer.hs:156, and 190 for events), and `onHit` performs the pgmq enqueue from the CLI (`ConsumeStream.hs:47-52` for stream hits, `ConsumeStream.hs:75-86` for event hits) using a separate connection acquisition (`Pool.use` in Enqueue.hs:54). A crash after the inbox transaction commits but before the enqueue loses the run forever: the redelivered record is answered with `InboxDuplicate` (Consumer.hs:157) and never re-fires. The handler passed to the inbox, `inboxHandler` (Consumer.hs:198-208), is pure — it just returns the matching agents wrapped in `pure` — so nothing currently exploits the transactional boundary.

No Kafka resilience. `runKafkaConsumer props sub loop` is run once under `runError @KafkaError` (Consumer.hs:84); any `KafkaError` (broker restart, rebalance timeout) exits with one stderr line (Consumer.hs:86, 113) and the function returns — the process stops consuming.

Supporting pieces touched: `runJobFromEnvelope :: AgentDecl -> ActivityEnvelope -> RunJob` is the pure stream-hit→job builder (its epoch fallback is fixed by docs/plans/20, not here); the event-hit path builds a `TriggeredByEvent` job with idempotency key `agentName <> ":" <> messageId`. `Shikigami.Agent.RunJob.RunJob` is the queue payload type. The worker draining the queue is unaffected by this plan.

Test infrastructure: `withShikigamiMigratedDatabase` (`shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs`) provisions a per-test Postgres with all schemas migrated, including `keiro` (inbox tables) and `pgmq`. Kafka is not available in tests; the transactional core is therefore factored so it is testable without a broker, and the reconnect behavior is validated manually (the repo's `process-compose.yaml` runs a broker for the living-loop demo).


## Plan of Work

Milestone 1 — one transaction: inbox row + run-job message. Scope:
`shikigami-core/src/Shikigami/Trigger/Enqueue.hs`, the consumer vertical relocated to
`shikigami-workers` by plan 36, and its consume-stream/consume-events composition components.
At the end, a matched event's run job is enqueued inside the inbox transaction, and a crash
anywhere leaves either both facts or neither.

In `Shikigami/Trigger/Enqueue.hs`, add a transaction-composable send and a startup queue-ensurer:

```haskell
enqueueRunJobTx :: RunJob -> Tx.Transaction MessageId
ensureRunQueue :: Pool -> IO (Either UsageError ())
```

`enqueueRunJobTx` is `Tx.statement SendMessage { queueName = runQueueName, messageBody = MessageBody (toJSON job), delay = Nothing } Pgmq.Hasql.Statements.Message.sendMessage` — no `createQueue` inside the transaction. Import `Hasql.Transaction qualified as Tx` and the pgmq statement module (`shikigami-core.cabal` already depends on the package that exposes the `Pgmq` façade; add `pgmq-hasql` to the library's `build-depends` if the statement module is not re-exported — verify with `cabal build`). `ensureRunQueue` runs pgmq `createQueue runQueueName` once (`Pool.use`); pgmq's `create` is create-if-not-exists, so this is idempotent. The existing IO-level `enqueueRunJob` keeps working unchanged here; plan 20 is a downstream consumer and hardens it after this plan lands.

In `Shikigami/Trigger/Consumer.hs`, make the inbox handlers do the enqueue. Change `inboxHandler` (Consumer.hs:198-208) so that, for each matching agent, it builds the job with `runJobFromEnvelope` and enqueues it in the transaction:

```haskell
inboxHandler :: IncludeAgentActors -> [AgentDecl] -> IntegrationEvent -> Tx.Transaction [StreamHit]
inboxHandler include agents event =
  case decodeJsonIntegrationEvent event of
    Left _ -> pure []
    Right env -> do
      let matched = [a | a <- agents, Just m <- [streamMatchOf a], matchesStreamWith include m env]
      traverse_ (\a -> enqueueRunJobTx (runJobFromEnvelope a env)) matched
      pure [StreamHit (name a) env | a <- matched]
```

Mirror the change in `eventInboxHandler` (Consumer.hs:216-231): build the `TriggeredByEvent` `RunJob` inline (agent name, payload, `occurredAt = receivedAt`-style current time passed in from `processEventRecord`, idempotency key `name a <> ":" <> event ^. #messageId` — the same key `ConsumeStream.hs:82` uses today) and `enqueueRunJobTx` it before returning the hits. Note the enqueue is intentionally not deduplicated by pgmq — dedupe lives one level up: a redelivered Kafka record is `InboxDuplicate` and never reaches the handler, and the worker's keiro workflow id (the job's idempotency key) collapses any residual duplicates downstream.

Update the two consumer composition components in `shikigami-workers`: `onHit` in both
`runConsumeStream` and `runConsumeEvents` becomes logging-only; delete command-side enqueue
calls; call `ensureRunQueue (pool st)` once after the shared composition root acquires the
store and fail startup through its typed error path if it returns `Left`.

Milestone 2 — commit offsets only after durable terminal disposition. Scope: the
consumer module assigned by plan 36. At the end, the serial processor distinguishes
enqueued, duplicate, permanently dead-lettered, and transient-failure outcomes.

Introduce a disposition type and have both record processors return it:

```haskell
data RecordDisposition
  = Enqueued
  | Duplicate
  | PermanentlyDeadLettered !DeadLetterId
  | TransientFailure !Text
```

Rework both record processors so `InboxProcessed` yields `Enqueued`,
`InboxDuplicate` yields `Duplicate`, transient inbox/store/in-progress outcomes yield
`TransientFailure`, and any prior failed/handler-failed result is committed only after
the same transaction records a permanent dead-letter row. Decode failures follow the
same dead-letter path with topic, partition, offset, error, and a bounded payload digest/
sample. The framework commits only the first three terminal constructors. If dead-letter
persistence fails, return `TransientFailure` and leave the offset uncommitted.

Milestone 3 — serial framework supervision. Scope: the worker package and plan 37's
Settei Kafka settings. Register each subscription as a shibuya `Serial` processor (or
the verified equivalent serial mode) so record ordering and acknowledgement stay owned
by the framework. Apply the shared bounded retry policy to reconnectable broker/store
failures; programming exceptions escape so the process supervisor can restart it.

Do not add a second `commitOffsetMessage` loop around shibuya. Application code returns
the typed disposition; the adapter converts terminal dispositions to its commit/ack and
transient dispositions to retry. Tests assert exactly one commit decision per record and
strict serial order across a failure/redelivery boundary.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikigami` inside `nix develop`.

Edit per Plan of Work. After each milestone:

```bash
nix develop -c cabal build all
```

Create `shikigami-workers/test/Shikigami/StreamInboxSpec.hs` exporting `tests :: TestTree`; add `Shikigami.StreamInboxSpec` to `other-modules` of `test-suite shikigami-workers-test` in `shikigami-workers/shikigami-workers.cabal`; register `StreamInboxSpec.tests` in `shikigami-workers/test/Main.hs` (the suite already depends on `pgmq-hasql` and `shikigami-migrations:test-support`).

```bash
nix develop -c cabal test shikigami-workers-test --test-show-details=streaming
```

Expected transcript excerpt:

```text
StreamInbox
  matched event atomically records inbox row and enqueues run job:  OK
  redelivered event is InboxDuplicate and enqueues nothing:         OK
  handler failure rolls back both inbox row and message:            OK
  store failure yields TransientFailure and commits nothing:       OK
  poison record is durably dead-lettered before commit:             OK
  failed dead-letter persistence halts without commit:              OK
```

Manual Kafka-resilience check (needs the demo stack):

```bash
nix develop -c just create-database
nix develop -c process-compose up   # brings up Postgres + Kafka per process-compose.yaml
cabal run shikigami-consume-stream -- --config config/consume-stream-dev.yaml
# in another shell: restart the Kafka broker process
```

Expected consumer stderr: a `reconnecting in 1s: …` line (then 2s, 4s… if the broker stays down), followed by resumed `MATCH` lines once the broker returns — instead of today's single fatal `consumer error:` line and silence.


## Validation and Acceptance

Acceptance is a set of tests in `shikigami-workers/test/Shikigami/StreamInboxSpec.hs` that exercise the extracted transactional core against a real Postgres (`withShikigamiMigratedDatabase`), plus the manual broker-restart check above. To make the core testable without Kafka, factor record handling so the part after `integrationEventFromKafka` is an exported function taking the decoded event — for example `processDecodedActivity :: AppEnv -> IncludeAgentActors -> [AgentDecl] -> (StreamHit -> IO ()) -> IntegrationEvent -> Maybe KafkaDeliveryRef -> IO RecordDisposition` — and have the Shibuya handler call it. Tests then drive it with hand-built `IntegrationEvent`s (encode a sample `ActivityEnvelope` with `Keiro.Integration.Event.encodeJsonIntegrationEvent`, as `sinkIntentEvent` in `Shikigami/Agent/Workflow.hs` demonstrates).

Atomic success (fails before): with one declared stream agent matching the event, call the core once; assert disposition `Enqueued`, exactly one message on `shikigami_run_jobs` (read it back with pgmq-hasql `readMessage` through the pool and decode the `RunJob`, asserting its `idempotencyKey` is `<agent>:<activityId>`), and one completed inbox row. Before this plan the enqueue does not happen at all from the consumer module, so the message assertion fails.

Duplicate delivery: call the core twice with the same event; assert `Enqueued` then
`Duplicate`, one framework commit per terminal disposition, and exactly one queue message.

Atomic rollback (fails before): force enqueue failure inside the transaction. Assert
`TransientFailure`, an empty queue, no commit, and successful redelivery.

Store failure: run against an unavailable pool; assert `TransientFailure` and no commit.

Poison handling: feed garbage bytes; assert a durable dead-letter row contains delivery
coordinates, error, and bounded evidence before `PermanentlyDeadLettered` permits commit.
Force dead-letter persistence to fail and assert `TransientFailure` with no commit.

End-to-end behavior beyond tests: with the demo stack running and `PG_CONNECTION_STRING` set, stop Postgres, publish an activity fixture (`cabal run shikigami -- publish-fixture …`), observe the consumer log `RetryRecord`-driven reconnects without committing, restart Postgres, and observe the same event get processed and enqueued exactly once — where today it would have been committed-over and lost.


## Idempotence and Recovery

All edits are code-only; no migrations. Re-running tests is safe — each test gets a fresh database. The consumer changes are safe to deploy mid-stream: offsets already committed are unaffected, and the new commit policy only withholds commits on failures that previously lost data. Rolling back reintroduces the old hazards but breaks nothing operationally. One deployment note: after this plan the consumer requires the `shikigami_run_jobs` queue to exist at startup (`ensureRunQueue` creates it, idempotently), so no ordering constraint actually arises. If a crash occurs between the inbox transaction and the offset commit, the record is redelivered and answered with `InboxDuplicate` — by design, the run job was already enqueued in the committed transaction, so nothing is lost or duplicated.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 36, 37, and 47. The current reconciled cohort is Keiro
0.13.0.0, Shibuya core and Kafka adapter 0.9.0.0, and PGMQ 0.5.0.0, verified through
Mori, Hackage, and upstream tags. Queue creation remains outside the atomic inbox
transaction; plan 38/pg-migrate owns schema components, while this plan owns the all-or-nothing
runtime enqueue boundary.


## Interfaces and Dependencies

Hard dependencies: plans 36 and 37. Consumer code lives in the worker package and reads
Kafka/DLQ settings only through the Settei application config.

Libraries and why: keiro (`Keiro.Inbox.runInboxTransaction :: Maybe KeiroMetrics -> InboxDedupePolicy -> IntegrationEvent -> Maybe KafkaDeliveryRef -> (IntegrationEvent -> Tx.Transaction a) -> Eff es (Either InboxError (InboxResult a))` — verified in keiro `src/Keiro/Inbox.hs:80-88`; the handler runs inside the transaction, `attemptOneTx` at Inbox.hs:350-377; `Keiro.Inbox.Types.InboxResult (InboxProcessed, InboxDuplicate, InboxInProgress, InboxPreviouslyFailed, InboxHandlerFailed)`), hasql-transaction (`Hasql.Transaction` — `statement`, `condemn`), pgmq-hasql (`Pgmq.Hasql.Statements.Message.sendMessage :: Statement SendMessage MessageId` — verified transaction-composable; session-level `createQueue`, `readMessage` for tests), hasql-pool (`Pool`, `UsageError`), kafka-effectful (`runKafkaConsumer`, `KafkaError`, with offset storage delegated to the adapter), and `mori://shinzui/shibuya-kafka-adapter/packages/shibuya-kafka-adapter` (`kafkaAdapter`, serial polling and framework-owned ack finalization).

Signatures that must exist at the end (full module paths):

```haskell
-- shikigami-core/src/Shikigami/Trigger/Enqueue.hs
Shikigami.Trigger.Enqueue.enqueueRunJobTx :: RunJob -> Hasql.Transaction.Transaction MessageId
Shikigami.Trigger.Enqueue.ensureRunQueue :: Hasql.Pool.Pool -> IO (Either Hasql.Pool.UsageError ())

-- shikigami-workers/src/Shikigami/Trigger/Consumer.hs
data Shikigami.Trigger.Consumer.RecordDisposition
  = Enqueued | Duplicate | PermanentlyDeadLettered !DeadLetterId | TransientFailure !Text
Shikigami.Trigger.Consumer.processDecodedActivity ::
  AppEnv -> IncludeAgentActors -> [AgentDecl] -> (StreamHit -> IO ()) ->
  IntegrationEvent -> Maybe KafkaDeliveryRef -> IO RecordDisposition
Shikigami.Trigger.Consumer.processDecodedIntegrationEvent ::
  AppEnv -> [AgentDecl] -> (EventHit -> IO ()) ->
  IntegrationEvent -> Maybe KafkaDeliveryRef -> IO RecordDisposition
-- subscriptions are registered through shibuya's serial/framework-owned commit path.
```

Integration point (from the MasterPlan): this plan owns `enqueueRunJobTx` and
`ensureRunQueue`; plan 20 hard-depends on this plan, then hardens the IO-level helpers and
consumes `ensureRunQueue`. The `RunJob` idempotency-key conventions
(`<agent>:<activityId>` for stream, `<agent>:<messageId>` for events) are load-bearing for
the worker's workflow dedupe and must not change here.


## Revision Notes

- 2026-07-22: Recorded plan 20 as a hard downstream consumer of `ensureRunQueue` and
  removed the previous either-order/duplicate-helper fallback.
- 2026-07-22: Replaced log-and-skip poison handling with a durable dead-letter/halt
  policy, made every inbox result an explicit terminal/transient disposition, and moved
  serial acknowledgement/offset ownership to shibuya. Added plans 36/37 prerequisites.
- 2026-08-19: Reconciled the living plan after plans 36/37 and the newer dependency
  cohort: updated consumer/test ownership, recorded released dependency evidence, selected
  Shibuya Kafka adapter 0.9's serial ack path, and made the Shikigami-owned PGMQ poison
  queue explicit because the adapter intentionally has no DLQ producer.
- 2026-08-19: Recorded Milestone 1 implementation and validation, including the worker-suite
  relocation and the forced queue-send rollback proof.
- 2026-08-19: Recorded Milestones 2/3 implementation: Shibuya serial acknowledgement,
  bounded reconnect supervision, typed programming-failure escape, configured PGMQ poison
  storage, adapter key limitation, and the expanded 31-test worker acceptance suite.
