---
id: 4
slug: trigger-evaluators-and-the-activity-v1-stream-consumer
title: "Trigger Evaluators and the activity.v1 Stream Consumer"
kind: exec-plan
created_at: 2026-06-24T23:41:28Z
intention: "intention_01kvy04813ehbv9aghj3tn4zjx"
master_plan: "docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md"
---

# Trigger Evaluators and the activity.v1 Stream Consumer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami (式神 — a summoned spirit-servant bound to its master's will) is a runtime in which an
autonomous system agent is *declared*, not coded: you write a short typed Dhall file that says "run
**this behavior**, when **this trigger** fires, send the result to **these sinks**," and a thin
worker runs it forever. A *trigger* is the "when": this plan builds the part of the runtime that
answers, for each declared agent, the question **"is it time to run this agent right now?"** across
the three trigger kinds the design calls contract **C3**.

After this plan lands, someone can do all of the following from a fresh checkout of
`/Users/shinzui/Keikaku/bokuno/shikigami` inside its nix dev shell, and *see it work*:

1. **Schedule trigger.** Call a pure function `Shikigami.Trigger.Schedule.isDue cron now` with a
   standard five-field cron expression (for example `"* * * * *"` meaning "every minute") and a clock
   time, and get back `True`/`False` — proven by unit tests that pin specific cron strings to
   specific times.
2. **Stream trigger.** Start a Kafka broker (Redpanda) with `process-compose up`, run
   `cabal run shikigami -- publish-fixture fixtures/envelope.json` to publish one *Activity Envelope*
   (the canonical nine-field event shape) onto the one contract topic `activity.v1` with the exact
   `keiro-*` Kafka headers the keiro idempotent inbox requires, and watch a consumer
   (`cabal run shikigami -- worker --agents agents/`) log which declared agents *matched* that
   envelope. Publish the **same** envelope a second time and watch the keiro inbox report it as a
   duplicate (the consumer does not re-fire it). Publish an envelope whose `actor.kind` is `"agent"`
   and watch nothing match — the **feedback guard** that stops agents from reacting to their own
   output.
3. **Event trigger (addressed delivery).** Drop a small JSON job onto a `shinzui/pgmq-hs` queue (or
   POST it to an HTTP route), and watch the worker pick it up and treat it as a request to run a named
   agent directly — the path a `mori` automation action or a `kanmon` channel-inbound event uses to
   address a specific agent without going through the activity stream.

The user-visible payoff is that **a fired trigger enqueues a well-formed "run job" onto a pgmq
queue** — a row you can see with a `SELECT` — which the worker plan (`docs/plans/5-the-supervised-worker-and-run-orchestration.md`)
later drains to actually run the agent. Until that worker exists, this plan proves itself by asserting
that the job lands on the queue and that the match is logged, with deterministic unit tests for the
pure evaluators.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: added the `cron` Hackage dependency (cron-0.7.2) and `Shikigami.Trigger.Schedule` with
      `parseCron`/`isDue :: CronSchedule -> UTCTime -> Bool` (real five-field cron strings). ✅ 2026-06-24
- [x] M1: added `Shikigami.Trigger.Stream.matchesStream :: StreamMatch -> ActivityEnvelope -> Bool`
      (AND of present predicates + multi-verb list + the `actor.kind="agent"` feedback guard), plus
      `matchesStreamWith`/`IncludeAgentActors`. ✅
- [x] M1: tasty unit tests in `shikigami-core/test` — 8 cases (cron every-minute/0 9 * * * due+not-due/
      malformed; stream verb+subject match, absent-predicate ignored, non-match, agent excluded, opt-in
      include) all pass. ✅
- [ ] M2: add `process-compose.yaml` Redpanda broker process and a `just kafka-topic` helper that
      creates the `activity.v1` topic.
- [ ] M2: add the `Shikigami.Trigger.Stream.subscribeActivityStream` consumer (kafka-effectful direct)
      that maps each `ConsumerRecord` to a `KafkaInboundRecord`, calls
      `Keiro.Inbox.Kafka.integrationEventFromKafka`, decodes the envelope, dedupes via
      `Keiro.Inbox.runInboxTransaction`, and runs `matchesStream` per loaded agent.
- [ ] M2: add the `shikigami publish-fixture <envelope.json>` CLI subcommand that publishes one
      envelope with the exact `keiro-*` headers, and a `fixtures/envelope.json` sample.
- [ ] M2: prove the round-trip: `publish-fixture` → consumer logs the matched agent(s); re-publishing
      the same envelope is deduped (logged `InboxDuplicate`); an `actor.kind="agent"` envelope matches
      nothing.
- [ ] M3: define the **IP-7 run-job contract** (queue name + JSON body) in `shikigami-api`
      (`Shikigami.Api.RunJob`) and a small enqueue function `Shikigami.Trigger.Enqueue.enqueueRunJob`.
- [ ] M3: wire all three trigger paths to enqueue a run job (stream-match, schedule-due, addressed
      event) and add the addressed-event inbox (the shared pgmq agent-run queue drain + optional HTTP
      route).
- [ ] M3: prove a fired trigger lands a well-formed job on the pgmq queue (inspect with a `SELECT` or
      `pgmq.read`), and settle Open Questions 1/2/3/7 in the Decision Log.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: **Settle Open Question 1 (schedule evaluator source) by using the Hackage `cron` package
  (`System.Cron`), NOT `rei`'s `CronSchedule`.**
  Rationale: the spec's required signature is `isDue :: Cron -> UTCTime -> Bool` over standard
  five-field cron *strings* like `"* * * * *"`, and the seed schema's `Schedule : { cron : Text }`
  variant carries a free-text cron string. `rei`'s evaluator at
  `/Users/shinzui/Keikaku/bokuno/rei-project/rei/rei-core/src/Rei/Modules/AgentSchedule/Domain/CronSchedule.hs`
  is **not** a cron-string parser — it is a closed enum `CronSchedule = DailyAt | WeekdaysAt |
  WeeklyOn | EveryNHours` with a different signature `isDue :: CronSchedule -> UTCTime -> Maybe UTCTime
  -> Bool` (it needs the last-fired time). It is not exposed as a standalone library (it lives inside
  `rei-core`, an application package, not registered as a reusable cron lib in `mori`), and it cannot
  express arbitrary cron expressions. So we depend on the `cron` Hackage package, which parses real
  cron expressions (`parseCronSchedule :: Text -> Either String CronSchedule`) and answers
  `scheduleMatches :: CronSchedule -> UTCTime -> Bool`. We wrap it so our public type is
  `Shikigami.Trigger.Schedule.CronSchedule` (re-exporting the package's parser) and our `isDue` is the
  spec's `CronSchedule -> UTCTime -> Bool`.
  Date: 2026-06-24

- Decision: **Settle Open Question 2 (schedule drive mechanism): enqueue a due-time run job onto pgmq,
  do NOT busy-loop a timer inside this plan.** The schedule path is a periodic tick (a `worker` thread
  wakes once per minute, or a `pgmq`/`pg_cron` enqueue fires the tick) that, for each schedule-trigger
  agent, calls `isDue cron now` and — when due — enqueues exactly the same IP-7 run job onto the shared
  pgmq queue that stream and event triggers use.
  Rationale: this reuses substrate (one queue, one worker drain) and keeps the firing decision pure and
  testable (`isDue`) separate from the impure "what time is it / has it already fired this minute"
  concern. The MasterPlan's IP-7 explicitly notes "the schedule path may also enqueue a due-time job;
  the same queue/body convention applies." Suppression against double-firing the same minute is the
  worker's concern (the `shikigami_fired` table EP-1 owns and the worker plan uses); this plan's job is
  only the pure `isDue` + the enqueue.
  Date: 2026-06-24

- Decision: **Settle Open Question 3 (addressed-delivery transport): the shared pgmq agent-run queue is
  the primary transport; the HTTP route `POST /v1/agents/{name}/runs` is an optional thin convenience
  that itself enqueues onto the same queue.**
  Rationale: the queue decouples the callers (`mori`'s `Agent` action — IR-1; a `kanmon`
  channel-inbound event — IR-3) from shikigami's liveness: a caller can address an agent even when no
  shikigami worker is running, and the run happens when the worker next drains. The MasterPlan calls
  the queue path "preferred (reuses substrate, decouples mori/kanmon from shikigami liveness)". The
  HTTP route is built as a one-line servant handler that constructs the same `RunJob` and calls the
  same `enqueueRunJob`, so the two transports converge on one contract (IP-7) and there is exactly one
  code path that actually runs an agent (in the worker plan).
  Date: 2026-06-24

- Decision: **Settle Open Question 7 (stream offset/checkpoint policy): commit Kafka offsets only after
  the keiro inbox transaction commits, using manual (non-auto) offset commit, and rely on the keiro
  inbox's `(source, dedupe_key)` row for exactly-once *effect*.**
  Rationale: kafka-effectful's consumer supports `noAutoCommit` and `commitOffsetMessage`. We poll a
  record, run `integrationEventFromKafka` + `runInboxTransaction` (which inserts a `keiro_inbox` row
  keyed by the chosen `InboxDedupePolicy`), and only *after* that transaction returns
  `InboxProcessed`/`InboxDuplicate` do we `commitOffsetMessage` the record. A crash between the inbox
  commit and the offset commit replays the record on restart; the inbox then returns `InboxDuplicate`
  and we skip re-firing, then commit the offset. So a restart neither double-fires (inbox dedup
  guards) nor loses position (offset is only advanced past committed work). We use the default policy
  `PreferIntegrationMessageId` (stable across Kafka retries) unless an envelope carries a
  `keiro-source-event-id`, in which case `PreferSourceEventIdentity` collapses schema-upgrade
  republishes — we default to `PreferIntegrationMessageId` for simplicity and document the alternative.
  Date: 2026-06-24

- Decision: **Consume `shinzui/kafka-effectful` directly; never `shibuya-kafka-adapter`.**
  Rationale: the C3 caveat (verified in `docs/initial-spec.md`, "Why a new project") is that
  `shibuya-kafka-adapter` drops the `keiro-*` headers the keiro idempotent inbox needs to reconstruct
  an `IntegrationEvent`. The keiro inbox **requires** the headers `keiro-message-id`, `keiro-source`,
  `keiro-destination`, `keiro-event-type`, `keiro-schema-version`, and `content-type` (verified by
  reading `/Users/shinzui/Keikaku/bokuno/keiro`); a consumer that loses them gets a `MissingHeader`
  decode error. kafka-effectful preserves headers as `crHeaders :: Headers` (a `[(ByteString,
  ByteString)]`), so we use it directly.
  Date: 2026-06-24

- Decision: **The IP-7 run-job queue is named `shikigami_run_jobs` and the body is a JSON object
  shaped per `Shikigami.Api.RunJob` (see Interfaces and Dependencies).** This plan *defines* the queue
  name and body and *enqueues*; the worker plan
  (`docs/plans/5-the-supervised-worker-and-run-orchestration.md`) *drains*. The two must document the
  shape identically.
  Rationale: IP-7 is a shared contract; pinning the exact name and body here removes ambiguity for the
  worker plan.
  Date: 2026-06-24

- Decision: **The `keiro-*` Kafka header set produced by `publish-fixture` is documented identically to
  EP-3's `stub-kawa --republish` mode (IP-6).** Both produce the exact six required headers (and the
  optional `keiro-occurred-at` and `keiro-source-event-id`); the consumer here reads them. The set is
  pinned in Interfaces and Dependencies.
  Rationale: IP-6 requires EP-3 and EP-4 to agree byte-for-byte on the header set; this is the single
  point of truth and the EP-3 plan must mirror it.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**What shikigami is.** A four-package Haskell project (modeled on the `shinzui/kizashi` template). A
declared agent is a Dhall file `{ name, behavior, trigger, sinks }`. A *behavior* is what runs; a
*trigger* is when; *sinks* are what it produces. This plan owns the **trigger** evaluation.

**Where things live (full paths).**

- `/Users/shinzui/Keikaku/bokuno/shikigami/` — the repo root.
- `docs/initial-spec.md` — the frozen design. The sections that matter here are "The three triggers
  (contract C3)", the "Stream consumer" parts of "The worker", the "fixture topic + publish-fixture"
  paragraph, the "C9 keiro inbox seam", the CLI surface, and the Open Questions.
- `docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md` — the MasterPlan. It lists the
  Integration Points (IP-1..IP-9). This plan **owns IP-7** (the trigger→run pgmq job), **consumes
  IP-6** (the Activity Envelope and the Kafka header seam, defined by EP-1, shared with EP-3), and
  **soft-consumes IP-4** (EP-2's `runBehavior` — until the worker wires it, our fired trigger just
  enqueues a job).
- `process-compose.yaml` — already present, runs an ephemeral Postgres. This plan **adds** a Redpanda
  (Kafka) broker process to it.
- `agents/detectors/` — seed declarations authored before the runtime, annotated against a local
  placeholder schema `agents/detectors/schema.dhall`. Read them to understand the stream-match shape
  the matcher must support (an `Observe` trigger with `topic`, `subjectType`, and `verbs`). EP-6
  re-points these at the canonical schema; this plan does not touch them.
- The four Haskell packages (created by EP-1, `docs/plans/1-scaffold-agent-schema-loader-and-validate-cli.md`):
  - `shikigami-api/` — client-safe wire types (no `hasql`/`effectful`/`kiroku`). Owns `AgentDecl`,
    `Trigger`, `StreamMatch`, `Sink`, and the nine-field `ActivityEnvelope` (IP-1/IP-6). This plan
    **adds** `Shikigami.Api.RunJob` (the IP-7 job body) here.
  - `shikigami-core/` — the runtime. This plan **adds** `Shikigami.Trigger.Schedule`,
    `Shikigami.Trigger.Stream`, and `Shikigami.Trigger.Enqueue` here, plus their tests in
    `shikigami-core/test`.
  - `shikigami-cli/` — the `shikigami` executable (`optparse-applicative`). This plan **adds** the
    `publish-fixture` subcommand and the stream-consumer wiring used by the `worker` subcommand's
    trigger half.
  - `shikigami-migrations/` — SQL + a test-support sublibrary `withShikigamiMigratedDatabase`. This
    plan does not add migrations (the run queue is created idempotently by `pgmq`'s `createQueue`),
    but uses the test-support sublibrary to get an ephemeral Postgres for the enqueue tests.

**Terms of art, defined.**

- *Activity Envelope* — the canonical nine-field event shape every activity in the platform takes:
  `activity_id` (a UUIDv7 string the publisher mints itself), `occurred_at` (an RFC3339 timestamp),
  `source` (an internal identity string, e.g. `"shinzui/shikigami"`), `actor` (`{ kind, id, session?
  }` where `kind` is `"human" | "agent" | "service"`), `subject` (`{ type, id }` — what the activity
  is about), `verb` (a past-tense dotted string like `"digest.produced"`), `payload` (free-form JSON),
  `context_refs` (a list of `{ scheme, ref }` back-references), and `idempotency_key`. Defined once by
  EP-1 in `shikigami-api`; this plan **decodes** it from the stream.
- *activity.v1* — the single Kafka topic on which all activities flow. Consumers bind this *one* topic,
  never raw per-service topics. Until the real `kawa` service publishes it, this plan uses a **fixture
  topic** of the same name on a local Redpanda broker, fed by `publish-fixture`.
- *keiro idempotent inbox* — `shinzui/keiro` is the integration-event backbone. Its inbox reconstructs
  an `IntegrationEvent` from a Kafka record using `keiro-*` headers and records a row keyed by a
  dedupe key so the same logical event is processed at most once. This is contract **C9**.
- *IntegrationEvent* — keiro's transport envelope: it carries `payloadBytes :: ByteString` (the raw
  body) plus routing metadata. Our Activity Envelope JSON is the `payloadBytes`; we decode it after the
  inbox accepts the record.
- *pgmq* — `shinzui/pgmq-hs`, a Postgres-backed message queue. A *queue* holds JSON message bodies; you
  `sendMessage` to enqueue and `readMessage` to drain.
- *feedback guard* — the rule that a stream-trigger agent does NOT fire on an envelope whose
  `actor.kind` is `"agent"`, so agents do not react to their own (or each other's) output in a loop —
  unless the agent explicitly opts in.
- *run job* — the JSON message this plan enqueues onto the `shikigami_run_jobs` pgmq queue when a
  trigger fires; the worker plan drains it and runs the agent. This is IP-7.

**Verified library facts (read from source during planning — do not re-derive).**

- `shinzui/kafka-effectful` at `/Users/shinzui/Keikaku/bokuno/kafka-effectful`. Consumer:
  `runKafkaConsumer :: (IOE :> es, Error KafkaError :> es) => ConsumerProperties -> Subscription -> Eff (KafkaConsumer : es) a -> Eff es a`;
  `pollMessage :: (KafkaConsumer :> es) => Timeout -> Eff es (Maybe (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))`;
  `commitOffsetMessage :: (KafkaConsumer :> es) => OffsetCommit -> ConsumerRecord k v -> Eff es ()`.
  `ConsumerRecord` fields: `crTopic :: TopicName`, `crPartition :: PartitionId`, `crOffset :: Offset`,
  `crTimestamp :: Timestamp`, `crHeaders :: Headers`, `crKey :: k`, `crValue :: v`. `Headers` is
  `[(ByteString, ByteString)]` with `headersToList`/`headersFromList`. Consumer config builders:
  `brokersList [BrokerAddress]`, `groupId (ConsumerGroupId t)`, `noAutoCommit`; subscription:
  `topics [TopicName]`, `offsetReset Earliest`. Producer:
  `runKafkaProducer :: (IOE :> es, Error KafkaError :> es) => ProducerProperties -> Eff (KafkaProducer : es) a -> Eff es a`;
  `produceMessageSync :: (KafkaProducer :> es) => ProducerRecord -> Eff es Offset`. `ProducerRecord`
  fields: `prTopic`, `prPartition` (`UnassignedPartition`), `prKey :: Maybe ByteString`,
  `prValue :: Maybe ByteString`, `prHeaders :: Headers`.
- `shinzui/keiro` at `/Users/shinzui/Keikaku/bokuno/keiro`. Inbox:
  `Keiro.Inbox.Kafka.integrationEventFromKafka :: KafkaInboundRecord -> Either KafkaDecodeError (IntegrationEvent, KafkaDeliveryRef)`.
  `KafkaInboundRecord { topic :: Text, partition :: Int64, offset :: Int64, key :: Maybe Text, payload :: ByteString, headers :: [(Text, Text)], receivedAt :: UTCTime }`.
  `Keiro.Inbox.runInboxTransaction :: (IOE :> es, Store :> es) => Maybe KeiroMetrics -> InboxDedupePolicy -> IntegrationEvent -> Maybe KafkaDeliveryRef -> (IntegrationEvent -> Tx.Transaction a) -> Eff es (Either InboxError (InboxResult a))`.
  `InboxDedupePolicy = PreferIntegrationMessageId | PreferSourceEventIdentity | KafkaDeliveryIdentity | CustomDedupeKey Text`.
  `InboxResult a = InboxProcessed a | InboxDuplicate | InboxInProgress | InboxPreviouslyFailed (Maybe Text) | InboxHandlerFailed Text Int`.
  `IntegrationEvent { messageId :: Text, source :: Text, destination :: Text, key :: Maybe Text, eventType :: Text, schemaVersion :: Int, contentType :: IntegrationContentType, schemaReference :: Maybe SchemaReference, sourceEventId :: Maybe EventId, sourceGlobalPosition :: Maybe GlobalPosition, payloadBytes :: ByteString, occurredAt :: UTCTime, causationId :: Maybe EventId, correlationId :: Maybe EventId, traceContext :: Maybe TraceContext, attributes :: Maybe Value }`.
  **Required `keiro-*` headers** (missing → `MissingHeader`): `keiro-message-id`, `keiro-source`,
  `keiro-destination`, `keiro-event-type`, `keiro-schema-version`, and `content-type` (no prefix).
  **Optional**: `keiro-occurred-at`, `keiro-source-event-id`, `keiro-correlation-id`,
  `keiro-causation-id`, `keiro-attributes`, `traceparent`, `tracestate`, and the schema-* headers.
  The inbox dedupe is a Postgres `keiro_inbox` table with `ON CONFLICT (source, dedupe_key) DO
  NOTHING`. JSON codec helper: `decodeJsonIntegrationEvent :: (FromJSON a) => IntegrationEvent -> Either IntegrationEventError a`
  (decodes `payloadBytes`).
- `shinzui/pgmq-hs` at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`. The
  `pgmq-hasql` package exposes hasql `Session` operations: `createQueue :: QueueName -> Session ()`;
  `sendMessage :: SendMessage -> Session MessageId` where
  `SendMessage { queueName :: QueueName, messageBody :: MessageBody, delay :: Maybe Delay }`;
  `readMessage :: ReadMessage -> Session (Vector Message)` where
  `ReadMessage { queueName :: QueueName, delay :: Delay, batchSize :: Maybe Int32, conditional :: Maybe Value }`.
  `MessageBody` is `newtype MessageBody { unMessageBody :: Value }` (JSON). `QueueName` is built by
  `parseQueueName :: Text -> Either PgmqError QueueName`. `Message { messageId :: MessageId, visibilityTime, enqueuedAt, lastReadAt, readCount :: Int64, body :: MessageBody, headers :: Maybe Value }`.
  Run a `Session` with `Hasql.Pool.use :: Pool -> Session a -> IO (Either UsageError a)`. There is
  also a `pgmq-effectful` variant (`runPgmq :: Pool -> Eff (Pgmq : es) a -> Eff es a`,
  `sendMessage :: (Pgmq :> es) => SendMessage -> Eff es MessageId`).
- The `cron` Hackage package (`System.Cron`, `System.Cron.Parser`):
  `parseCronSchedule :: Text -> Either String CronSchedule`,
  `scheduleMatches :: CronSchedule -> UTCTime -> Bool`, and a `Show`/`Eq` `CronSchedule`. Pinned in
  `cabal.project` (EP-1's pin-set, IP-8); if not on the package index, add a `source-repository-package`
  for `hackage`'s `cron` or vendor it — confirm the exact API surface against the resolved version at
  M1 (the two functions above are stable across 0.6–0.7).

**Coding conventions (IP-9, mandatory).** GHC 9.12.4 + `GHC2024`; every cabal stanza does
`import: common` from a `common` stanza enabling `DeriveAnyClass`/`DuplicateRecordFields`/
`OverloadedLabels`/`OverloadedStrings` (+ `MultilineStrings`); postpositive `qualified` imports (e.g.
`import Data.Text qualified as Text`); a `Shikigami.Prelude` that does **not** re-export
`Data.Generics.Labels`; no field prefixes, strict `!` fields, explicit deriving strategies, lens
operators over record-update syntax. Browse the conventions with `mori registry docs haskell-jitsurei`
before writing Haskell.


## Plan of Work

The work is three milestones, each independently verifiable. M1 is pure and needs no broker or
database; M2 adds the live Kafka consumer and the fixture-publish CLI; M3 adds the run-job enqueue and
the addressed-event inbox.

### Milestone M1 — the pure evaluators

**Scope.** Two pure functions and their tests, plus the `cron` dependency. At the end of M1,
`shikigami-core` exports `Shikigami.Trigger.Schedule.isDue` and `Shikigami.Trigger.Stream.matchesStream`,
and `cabal test shikigami-core` passes a tasty/hedgehog suite that pins concrete behavior. No broker,
no database, no model.

**What will exist.** `shikigami-core/src/Shikigami/Trigger/Schedule.hs` and
`shikigami-core/src/Shikigami/Trigger/Stream.hs` (the matcher half), plus
`shikigami-core/test/Shikigami/Trigger/ScheduleSpec.hs` and
`shikigami-core/test/Shikigami/Trigger/StreamSpec.hs`, wired into the existing tasty test driver.

`Shikigami.Trigger.Schedule` wraps the `cron` package. Its public type is a newtype over the package's
`CronSchedule` so callers go through us:

```haskell
module Shikigami.Trigger.Schedule
  ( CronSchedule
  , parseCron
  , isDue
  ) where

import System.Cron qualified as Cron
import System.Cron.Parser qualified as Cron

newtype CronSchedule = CronSchedule Cron.CronSchedule
  deriving stock (Eq, Show)

-- | Parse a standard five-field cron expression ("min hour day-of-month month day-of-week").
parseCron :: Text -> Either Text CronSchedule
parseCron t = bimap Text.pack CronSchedule (Cron.parseCronSchedule t)

-- | True when the cron expression matches the given instant (to the minute).
isDue :: CronSchedule -> UTCTime -> Bool
isDue (CronSchedule s) = Cron.scheduleMatches s
```

`Shikigami.Trigger.Stream.matchesStream` implements the AND-of-present-predicates matcher plus the
feedback guard. It consumes `StreamMatch` and `ActivityEnvelope` from `shikigami-api` (defined by
EP-1). The feedback guard requires knowing whether the agent opted in; the spec's `StreamMatch` does
not carry an opt-in field, so we thread it as an explicit parameter and provide a convenience that
reads it from the envelope/agent. To keep the spec's exact signature, `matchesStream` *applies the
guard by default* (excludes `actor.kind="agent"`), and a second function `matchesStreamWith` takes an
explicit `IncludeAgentActors` flag for the opt-in case:

```haskell
module Shikigami.Trigger.Stream
  ( matchesStream
  , matchesStreamWith
  , IncludeAgentActors (..)
  -- (subscribeActivityStream is added in M2)
  ) where

data IncludeAgentActors = ExcludeAgentActors | IncludeAgentActors
  deriving stock (Eq, Show)

-- | AND of present predicates; excludes actor.kind="agent" by default (the feedback guard).
matchesStream :: StreamMatch -> ActivityEnvelope -> Bool
matchesStream = matchesStreamWith ExcludeAgentActors

matchesStreamWith :: IncludeAgentActors -> StreamMatch -> ActivityEnvelope -> Bool
matchesStreamWith include m env =
     guardActor include env
  && maybe True (== env.verb)              m.verb
  && maybe True (== env.source)            m.source
  && maybe True (== env.subject.type_)     m.subjectType
  where
    guardActor IncludeAgentActors _ = True
    guardActor ExcludeAgentActors e = e.actor.kind /= "agent"
```

(The exact field accessors — `env.verb`, `env.source`, `env.subject`, `env.actor.kind` — follow EP-1's
`ActivityEnvelope` shape. If EP-1 named the subject-type field differently, adapt the accessor; the
*behavior* — AND of present predicates, guard on `actor.kind == "agent"` — is what is load-bearing.)

**How the agent opts in.** A stream-trigger agent that legitimately wants to react to agent-produced
activities (rare; only meta-detectors) sets the opt-in. Since the seed schema's `Observe` trigger does
not yet carry that flag, the canonical schema (EP-1) should add an optional
`includeAgentActors : Bool` defaulting `False` to `StreamMatch`/`Observe`; until it does, the worker
passes `ExcludeAgentActors` for every agent (the safe default), and the override is a documented
follow-on. Record this as a Surprise if EP-1's schema lacks the field when you reach M2.

**Commands and acceptance.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
nix develop --command cabal test shikigami-core --test-options='-p Trigger'
```

Acceptance: the `Trigger.Schedule` group proves `isDue (parse "* * * * *") t == True` for any `t`,
`isDue (parse "0 9 * * *") (09:00) == True`, and `isDue (parse "0 9 * * *") (10:00) == False`; the
`Trigger.Stream` group proves a match on `verb`, a match when a predicate is `Nothing`, a non-match
on a differing `verb`, exclusion of `actor.kind="agent"` under `matchesStream`, and inclusion under
`matchesStreamWith IncludeAgentActors`.

### Milestone M2 — the activity.v1 consumer + publish-fixture

**Scope.** Stand up a Redpanda broker via `process-compose.yaml`, add the live Kafka consumer that
decodes a fixture envelope through the keiro inbox and runs `matchesStream`, and add the
`publish-fixture` CLI. At the end of M2 you can publish one envelope and watch the consumer log the
matched agent(s); re-publishing is deduped; an `actor.kind="agent"` envelope matches nothing.

**What will exist.** A Redpanda process in `process-compose.yaml` plus a `just kafka-topic` recipe;
`Shikigami.Trigger.Stream.subscribeActivityStream`; the `Shikigami.Cli.Commands.PublishFixture`
subcommand; and `fixtures/envelope.json`.

The consumer (`subscribeActivityStream`) is an `effectful` program that runs a `runKafkaConsumer`
poll loop. For each polled `ConsumerRecord`:

1. Build a `Keiro.Inbox.Kafka.KafkaInboundRecord` from the record:
   `topic = topicNameText crTopic`, `partition = fromIntegral crPartition`,
   `offset = fromIntegral crOffset`, `key = decodeUtf8 <$> crKey`,
   `payload = fromMaybe mempty crValue`,
   `headers = [(decodeUtf8 k, decodeUtf8 v) | (k,v) <- headersToList crHeaders]`,
   `receivedAt = <now>`.
2. Call `integrationEventFromKafka record`. On `Left err`, log the decode error and **skip + commit
   the offset** (a malformed record must not block the partition — it is dead-lettered by logging,
   not retried forever). This is where a missing `keiro-*` header surfaces as `MissingHeader`.
3. On `Right (event, kafkaRef)`, call
   `runInboxTransaction Nothing PreferIntegrationMessageId event (Just kafkaRef) handler`. The
   `handler :: IntegrationEvent -> Tx.Transaction ()` decodes the Activity Envelope from
   `payloadBytes` (via `decodeJsonIntegrationEvent`) and, for each loaded agent whose trigger is a
   `StreamTrigger`, evaluates `matchesStream agent.match env`; for each match it builds the IP-7
   `RunJob` (M3) and enqueues it (M3 wires the actual enqueue; in M2 the handler just *logs* the
   matched agent names, so M2 is provable before the queue exists).
4. Inspect the `InboxResult`: `InboxProcessed ()` → matched & handled (log it); `InboxDuplicate` →
   log "deduped" and do nothing; other results → log.
5. **Only now** `commitOffsetMessage OffsetCommit record` (manual commit, after the inbox tx) — the
   Open-Question-7 checkpoint policy.

```haskell
subscribeActivityStream :: StreamConfig -> [AgentDecl] -> (StreamHit -> Eff es ()) -> Eff es ()
-- StreamConfig { broker :: Text, topic :: Text, groupId :: Text }
-- StreamHit { agentName :: Text, envelope :: ActivityEnvelope }  -- what fired
```

The `publish-fixture` CLI reads a JSON file holding an Activity Envelope, wraps it as the
`payloadBytes` of a `keiro` `IntegrationEvent`, and produces ONE `ProducerRecord` onto `activity.v1`
with the exact `keiro-*` headers (see Interfaces and Dependencies for the header list), using
`runKafkaProducer` + `produceMessageSync`. The Kafka **message key** is the envelope's `subject.id`
(the topic is subject-keyed per C3). The `keiro-message-id` header is the envelope's `activity_id`
(stable, so re-publishing the same file dedupes).

**Commands and acceptance.** In one terminal:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
nix develop --command process-compose up
```

This must bring up `postgres`, `redpanda`, and create the `activity.v1` topic. In a second terminal:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
nix develop --command cabal run shikigami -- worker --agents agents/ --broker localhost:19092 --topic activity.v1
```

Then in a third terminal publish a fixture that matches a declared stream agent, then publish it
again, then publish an agent-actor one:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
nix develop --command cabal run shikigami -- publish-fixture fixtures/envelope.json
nix develop --command cabal run shikigami -- publish-fixture fixtures/envelope.json
nix develop --command cabal run shikigami -- publish-fixture fixtures/envelope-agent.json
```

Acceptance (watch the worker terminal): the first publish logs a match line naming the agent(s) whose
`matchesStream` returned true; the second publish logs a "deduped (InboxDuplicate)" line and no match;
the agent-actor publish logs "no match (feedback guard)". The exact transcript is shown in Concrete
Steps.

### Milestone M3 — the run-job enqueue + addressed-event inbox

**Scope.** Define the IP-7 run-job contract, enqueue a job from all three trigger paths, and add the
addressed-event inbox (the shared pgmq agent-run queue + an optional HTTP route). At the end of M3, a
fired trigger lands a well-formed JSON job on the `shikigami_run_jobs` pgmq queue, observable by a
`SELECT`.

**What will exist.** `shikigami-api/src/Shikigami/Api/RunJob.hs` (the wire type);
`shikigami-core/src/Shikigami/Trigger/Enqueue.hs` (`enqueueRunJob`); the stream handler (M2) now calls
`enqueueRunJob` instead of only logging; a schedule tick (`Shikigami.Trigger.Schedule.dueAgents` +
enqueue) ; and the addressed-event inbox: a drain of the same queue is the *worker's* job (EP-5), but
this plan adds the **producer** side for the addressed path — a function `enqueueAddressedRun` plus an
optional servant route `POST /v1/agents/{name}/runs` that calls it.

The IP-7 job body (`Shikigami.Api.RunJob`):

```haskell
data TriggerKind = TriggeredBySchedule | TriggeredByStream | TriggeredByEvent
  deriving stock (Eq, Show, Generic)

data RunJob = RunJob
  { agentName       :: !Text          -- which declared agent to run
  , triggerKind     :: !TriggerKind   -- which class fired
  , occurredAt      :: !UTCTime       -- the trigger occurrence time (envelope occurred_at / now)
  , triggerPayload  :: !Value         -- the trigger payload (the full Activity Envelope JSON for
                                       --   stream; the addressed payload for event; {} for schedule)
  , idempotencyKey  :: !Text          -- derived from (agentName, trigger occurrence); the worker
                                       --   uses this to avoid double-running the same occurrence
  }
  deriving stock (Eq, Show, Generic)
```

`idempotencyKey` is derived deterministically: for a stream trigger it is
`agentName <> ":" <> env.activity_id`; for a schedule trigger it is
`agentName <> ":sched:" <> iso8601 (truncateToMinute now)`; for an event trigger it is
`agentName <> ":evt:" <> <caller-supplied-id or a hash of the payload>`. This makes re-firing the same
occurrence land an *identical* job body, so the worker's own dedup (and the `shikigami_fired`
suppression table EP-1 owns) collapses duplicates.

`enqueueRunJob` writes the job onto the `shikigami_run_jobs` queue:

```haskell
enqueueRunJob :: Pool -> RunJob -> IO (Either UsageError MessageId)
enqueueRunJob pool job =
  Pool.use pool $ do
    Pgmq.createQueue runQueue                 -- idempotent; first call creates it
    Pgmq.sendMessage SendMessage
      { queueName = runQueue
      , messageBody = MessageBody (toJSON job)
      , delay = Nothing
      }
  where
    Right runQueue = Pgmq.parseQueueName "shikigami_run_jobs"
```

**Commands and acceptance.** Start Postgres (and Redpanda for the stream path):

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
nix develop --command process-compose up
```

Stream path — publish a matching fixture and confirm a job landed:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
nix develop --command cabal run shikigami -- worker --agents agents/ --broker localhost:19092 --topic activity.v1 &
nix develop --command cabal run shikigami -- publish-fixture fixtures/envelope.json
nix develop --command psql "$SHIKIGAMI_DATABASE_URL" -c "SELECT message::jsonb ->> 'agentName', message::jsonb ->> 'triggerKind' FROM pgmq.q_shikigami_run_jobs;"
```

Event path — address an agent directly via the queue (or the HTTP route) and confirm a job landed:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
nix develop --command cabal run shikigami -- enqueue-run heartbeat --payload '{"hello":"world"}'
nix develop --command psql "$SHIKIGAMI_DATABASE_URL" -c "SELECT message::jsonb ->> 'agentName', message::jsonb ->> 'triggerKind' FROM pgmq.q_shikigami_run_jobs;"
```

Acceptance: the `SELECT` returns a row whose `agentName` is the matched/addressed agent and whose
`triggerKind` is `TriggeredByStream` / `TriggeredByEvent`. The schedule path is proven by a unit test
that calls the due-evaluation + enqueue against the ephemeral Postgres (via
`withShikigamiMigratedDatabase`) and asserts a row lands. Exact transcripts are in Concrete Steps.


## Concrete Steps

State the exact commands to run and where to run them. Working directory is always
`/Users/shinzui/Keikaku/bokuno/shikigami`. All `cabal`/`psql`/`process-compose` commands run inside
`nix develop` (the project's dev shell, established by EP-1's `flake.nix`).

**Prerequisite: EP-1 is Complete.** This plan compiles only after EP-1 has scaffolded the four
packages, the `shikigami-api` wire types (`AgentDecl`, `Trigger`, `StreamMatch`, `ActivityEnvelope`),
the `cabal.project` pin-set, and `Shikigami.Prelude`. If `nix develop --command cabal build all` fails
because those do not exist, stop and complete EP-1 first.

### M1 steps

1. Add the `cron` package to `shikigami-core/shikigami-core.cabal` `build-depends`. Confirm the
   resolved version provides `System.Cron.Parser.parseCronSchedule` and `System.Cron.scheduleMatches`:

```bash
nix develop --command bash -lc 'ghc-pkg --simple-output field cron version || cabal build --dependencies-only shikigami-core'
```

2. Create `shikigami-core/src/Shikigami/Trigger/Schedule.hs` and
   `shikigami-core/src/Shikigami/Trigger/Stream.hs` (matcher half only) with the modules shown in the
   Plan of Work. Add both modules to the `exposed-modules` of `shikigami-core.cabal`.

3. Create the tasty/hedgehog specs `shikigami-core/test/Shikigami/Trigger/ScheduleSpec.hs` and
   `.../StreamSpec.hs`, wired into the existing test driver (the `main = defaultMain (testGroup …)`
   that EP-1's scaffold provides). Run:

```bash
nix develop --command cabal test shikigami-core --test-options='-p Trigger'
```

Expected transcript (abridged):

```text
Trigger.Schedule
  every-minute is always due:        OK
  0 9 * * * due at 09:00:            OK
  0 9 * * * not due at 10:00:        OK
Trigger.Stream
  verb match:                        OK
  absent predicate ignored:          OK
  differing verb does not match:     OK
  actor.kind=agent excluded:         OK
  opt-in includes agent actor:       OK

All 8 tests passed (0.03s)
```

### M2 steps

4. Add a Redpanda broker to `process-compose.yaml`. The existing file runs `postgres` and
   `create_schema`. Append a `redpanda` process and a `kafka_topic` one-shot. Redpanda speaks the
   Kafka protocol and needs no ZooKeeper. Use the `redpanda` binary from the nix dev shell (EP-1 adds
   it to `flake.nix` `devShell` packages; if absent, add `redpanda` to the shell's `buildInputs`):

```yaml
  redpanda:
    command: >
      rpk redpanda start
        --overprovisioned --smp 1 --memory 512M --reserve-memory 0M
        --node-id 0 --check=false
        --kafka-addr PLAINTEXT://0.0.0.0:19092
        --advertise-kafka-addr PLAINTEXT://localhost:19092
    is_daemon: false
    readiness_probe:
      exec:
        command: "rpk cluster info --brokers localhost:19092"
      initial_delay_seconds: 3
      period_seconds: 5
      failure_threshold: 10
    availability:
      restart: on_failure

  kafka_topic:
    command: "rpk topic create activity.v1 --brokers localhost:19092 -p 1 -r 1 || true"
    availability:
      restart: "no"
    depends_on:
      redpanda:
        condition: process_healthy
```

Also add a `Justfile` recipe `kafka-topic` for manual use:

```make
kafka-topic:
    rpk topic create activity.v1 --brokers localhost:19092 -p 1 -r 1 || true
```

5. Create `fixtures/envelope.json` (a matching envelope) and `fixtures/envelope-agent.json` (an
   `actor.kind="agent"` envelope that must NOT match). The matching one must satisfy at least one
   declared stream agent's `StreamMatch` — use a `verb`/`subject.type` the seed declarations expect
   (read `agents/detectors/*.dhall`; e.g. `subject.type = "intention"`, `verb =
   "intention.declared"`). Example:

```json
{
  "activity_id": "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b",
  "occurred_at": "2026-06-24T07:00:00Z",
  "source": "shinzui/rei",
  "actor": { "kind": "service", "id": "rei", "session": null },
  "subject": { "type": "intention", "id": "intention_abc" },
  "verb": "intention.declared",
  "payload": { "title": "ship shikigami" },
  "context_refs": [],
  "idempotency_key": "rei:intention_abc:declared"
}
```

`fixtures/envelope-agent.json` is the same but `"actor": { "kind": "agent", "id": "stall-watch" }`.

6. Implement `Shikigami.Trigger.Stream.subscribeActivityStream` (the poll loop in the Plan of Work)
   and the `publish-fixture` subcommand `Shikigami.Cli.Commands.PublishFixture`. Add `publish-fixture`
   to the `optparse-applicative` command parser in `shikigami-cli`. Add `kafka-effectful` and `keiro`
   to `shikigami-core.cabal` and `shikigami-cli.cabal` `build-depends`.

7. Build and run the round-trip (three terminals as in the Plan of Work). Expected worker transcript:

```text
[worker] subscribed activity.v1 @ localhost:19092 (group shikigami-stream)
[worker] activity 0190a1b2-… verb=intention.declared subject=intention/intention_abc
[worker]   MATCH agent=stalled-intention  (enqueue deferred — M3)
[worker] activity 0190a1b2-… InboxDuplicate (deduped)
[worker] activity 0190c3d4-… actor.kind=agent → no match (feedback guard)
```

### M3 steps

8. Create `shikigami-api/src/Shikigami/Api/RunJob.hs` with `RunJob`/`TriggerKind` and aeson instances
   (use `eventAesonOptions` per IP-9 if EP-1 exposes it; otherwise `defaultOptions`). Add to
   `exposed-modules`.

9. Create `shikigami-core/src/Shikigami/Trigger/Enqueue.hs` with `enqueueRunJob`, `enqueueAddressedRun`,
   and a helper `runJobFromEnvelope :: AgentDecl -> ActivityEnvelope -> RunJob`. Add `pgmq-hasql`,
   `hasql`, `hasql-pool` to `shikigami-core.cabal`.

10. Change the M2 stream handler to call `enqueueRunJob` after a match (keep the log line). Add the
    `enqueue-run <agent> --payload <json>` CLI subcommand (the addressed path producer) and, if time
    permits, the servant route `POST /v1/agents/{name}/runs` (a thin handler that builds the same
    `RunJob` with `triggerKind = TriggeredByEvent` and calls `enqueueAddressedRun`).

11. Add a schedule-tick test and an enqueue test under `shikigami-core/test` using
    `Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase`:

```bash
nix develop --command cabal test shikigami-core --test-options='-p Enqueue'
```

12. Run the end-to-end enqueue checks (Plan of Work commands). Expected `SELECT` output after a stream
    match and an addressed enqueue:

```text
   ?column?     |    ?column?
----------------+------------------
 stalled-intention | TriggeredByStream
 heartbeat         | TriggeredByEvent
(2 rows)
```

13. Update the Decision Log entries for Open Questions 1/2/3/7 to "settled" (they are pre-seeded
    above; confirm nothing changed during implementation), and fill Progress + Surprises.


## Validation and Acceptance

Acceptance is phrased as behavior a human can observe, not as "code compiles".

1. **Pure evaluators (M1).** `nix develop --command cabal test shikigami-core --test-options='-p
   Trigger'` exits 0 and prints the eight passing tests shown above. Specifically: `isDue` returns
   `True` for `"* * * * *"` at any minute, `True` for `"0 9 * * *"` at 09:00, `False` at 10:00; and
   `matchesStream` returns `True` on a matching `verb`, `True` when a predicate is `Nothing`, `False`
   on a differing `verb`, `False` for `actor.kind="agent"` (default guard), and `True` for an
   agent-actor envelope only under `matchesStreamWith IncludeAgentActors`.

2. **Stream consumer + dedup + feedback guard (M2).** With `process-compose up` and the `worker`
   running, `publish-fixture fixtures/envelope.json` causes the worker to log a `MATCH` line naming
   the agent(s) whose `matchesStream` returned true. A second identical publish logs
   `InboxDuplicate` and produces no new match — proving the keiro inbox dedupe across re-delivery.
   `publish-fixture fixtures/envelope-agent.json` logs `no match (feedback guard)` — proving the
   `actor.kind="agent"` exclusion end-to-end (not just in the unit test). A fixture missing a required
   `keiro-*` header logs a `MissingHeader` decode error and is skipped (does not crash the loop) —
   prove this by hand-editing a publish to drop `keiro-event-type`.

3. **Run-job enqueue (M3).** After a stream match (or an `enqueue-run` addressed call), a `SELECT …
   FROM pgmq.q_shikigami_run_jobs` returns a row whose body JSON has the matched/addressed
   `agentName`, the correct `triggerKind`, an `occurredAt`, the `triggerPayload` (the full envelope
   for stream; the supplied payload for event), and a deterministic `idempotencyKey`. Re-firing the
   same occurrence produces an identical body (same `idempotencyKey`), so the worker's later dedup is
   well-founded. This is the shared contract the worker plan
   (`docs/plans/5-the-supervised-worker-and-run-orchestration.md`) drains.

4. **Effective beyond compilation.** The MasterPlan's IP-4 is soft: until EP-5 wires `runBehavior`,
   "a fired trigger just enqueues a job." This plan's acceptance is exactly that — *a job lands on the
   queue and a match is logged* — which is observable without the behavior runner. When EP-5 lands, the
   same queue feeds the real run; no schema change here.


## Idempotence and Recovery

Every step is safe to repeat.

- **Pure tests (M1)** are stateless; re-run freely.
- **`process-compose up` (M2/M3)** is idempotent: `postgres` reuses `$PGDATA`; `redpanda` reuses its
  data dir; `kafka_topic` uses `rpk topic create … || true` so a pre-existing `activity.v1` is fine.
  To reset the broker, `process-compose down` then delete redpanda's data dir.
- **`publish-fixture`** is idempotent *by design*: the `keiro-message-id` header is the envelope's
  stable `activity_id`, so re-publishing the same file is deduped by the keiro inbox
  (`ON CONFLICT (source, dedupe_key) DO NOTHING`). The consumer logs `InboxDuplicate` and does not
  re-fire. This is the whole point of the dedupe proof.
- **The Kafka offset checkpoint (Open Question 7)** makes restarts safe: offsets are committed only
  *after* the inbox transaction commits. A crash between the inbox commit and the offset commit
  replays the record; the inbox returns `InboxDuplicate`; the consumer skips and commits the offset.
  So a restart never double-fires and never loses position. To intentionally re-process from the start
  (e.g. after wiping the inbox table), use a fresh `groupId` or `rpk group seek` to `--to start`.
- **`enqueueRunJob`** calls `createQueue` first, which is idempotent (pgmq's create is a no-op if the
  queue exists). Enqueuing the same `RunJob` twice lands two messages, but they share an
  `idempotencyKey` so the worker (EP-5) collapses them; this plan does not delete queue rows.
- **Rollback.** This plan adds only new modules, a CLI subcommand, two `process-compose` processes,
  and one pgmq queue (created lazily). To undo: remove the new modules and `build-depends`, drop the
  `redpanda`/`kafka_topic` processes from `process-compose.yaml`, and `SELECT pgmq.drop_queue(
  'shikigami_run_jobs')` if you want the queue gone. No migrations are added, so there is nothing to
  un-migrate.


## Interfaces and Dependencies

Name the libraries, modules, services, types, and signatures that must exist at the end of each
milestone. Full module paths throughout.

### Libraries consumed (used as-is)

- **`cron` (Hackage, `System.Cron` / `System.Cron.Parser`)** — schedule evaluation.
  `parseCronSchedule :: Text -> Either String System.Cron.CronSchedule`;
  `scheduleMatches :: System.Cron.CronSchedule -> UTCTime -> Bool`. *Why:* the spec requires real
  five-field cron strings; `rei`'s enum-based evaluator cannot express them and is not a library (see
  Decision Log, Open Question 1).
- **`shinzui/kafka-effectful`** (`/Users/shinzui/Keikaku/bokuno/kafka-effectful`) — the direct Kafka
  consumer and producer (NOT `shibuya-kafka-adapter`, which drops `keiro-*` headers). Signatures in
  Context and Orientation. *Why:* it preserves headers as `crHeaders`/`prHeaders`.
- **`shinzui/keiro`** (`/Users/shinzui/Keikaku/bokuno/keiro`) — the idempotent inbox (C9).
  `Keiro.Inbox.Kafka.integrationEventFromKafka`, `Keiro.Inbox.runInboxTransaction`,
  `Keiro.Integration.Event.IntegrationEvent`, `decodeJsonIntegrationEvent`. Signatures in Context and
  Orientation. *Why:* it reconstructs the IntegrationEvent and dedupes delivery.
- **`shinzui/pgmq-hs`** (`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`,
  `pgmq-hasql`) — the run-job queue. `createQueue`, `sendMessage`, `parseQueueName`, `MessageBody`,
  `SendMessage`. Signatures in Context and Orientation. *Why:* the IP-7 transport.
- **`hasql` / `hasql-pool`** — to run pgmq `Session`s (`Pool.use`).
- **`shinzui/shibuya`** — only indirectly: the worker plan (EP-5) supplies the `QueueProcessor` that
  drains `shikigami_run_jobs`. This plan does NOT build the drain; it builds the producers.

### Wire types this plan adds (in `shikigami-api`)

```haskell
-- Shikigami.Api.RunJob  (IP-7 — the shared trigger→run contract)
data TriggerKind = TriggeredBySchedule | TriggeredByStream | TriggeredByEvent
  deriving stock (Eq, Show, Generic)

data RunJob = RunJob
  { agentName      :: !Text
  , triggerKind    :: !TriggerKind
  , occurredAt     :: !UTCTime
  , triggerPayload :: !Value
  , idempotencyKey :: !Text
  }
  deriving stock (Eq, Show, Generic)
-- with FromJSON/ToJSON instances (no hasql/effectful deps — client-safe per IP-1)
```

The pgmq **queue name** is `shikigami_run_jobs` (the worker plan reads from the same name). The pgmq
message **body** is `toJSON (job :: RunJob)`.

### Functions this plan adds (in `shikigami-core` / `shikigami-cli`)

```haskell
-- Shikigami.Trigger.Schedule
newtype CronSchedule          -- wraps System.Cron.CronSchedule
parseCron :: Text -> Either Text CronSchedule
isDue     :: CronSchedule -> UTCTime -> Bool

-- Shikigami.Trigger.Stream
data IncludeAgentActors = ExcludeAgentActors | IncludeAgentActors
matchesStream     :: StreamMatch -> ActivityEnvelope -> Bool          -- guard ON by default
matchesStreamWith :: IncludeAgentActors -> StreamMatch -> ActivityEnvelope -> Bool
data StreamConfig = StreamConfig { broker :: !Text, topic :: !Text, groupId :: !Text }
data StreamHit    = StreamHit { agentName :: !Text, envelope :: !ActivityEnvelope }
subscribeActivityStream :: StreamConfig -> [AgentDecl] -> (StreamHit -> IO ()) -> IO ()

-- Shikigami.Trigger.Enqueue
runJobFromEnvelope :: AgentDecl -> ActivityEnvelope -> RunJob
enqueueRunJob      :: Pool -> RunJob -> IO (Either UsageError MessageId)
enqueueAddressedRun :: Pool -> Text -> Value -> IO (Either UsageError MessageId)  -- agentName, payload

-- Shikigami.Cli.Commands.PublishFixture
publishFixture :: PublishOpts -> IO ()   -- reads envelope.json, produces 1 record with keiro-* headers
-- Shikigami.Cli.Commands.EnqueueRun
enqueueRunCmd  :: EnqueueOpts -> IO ()    -- the addressed-event producer
```

### The exact `keiro-*` Kafka header set (IP-6 — must match EP-3's `stub-kawa --republish`)

`publish-fixture` produces these headers on the single `activity.v1` record; the consumer reads them
via the keiro inbox. **Required** (omitting any one makes `integrationEventFromKafka` fail with
`MissingHeader`):

```text
keiro-message-id      = <envelope.activity_id>          (stable; the dedupe key under PreferIntegrationMessageId)
keiro-source          = <envelope.source>               (e.g. "shinzui/rei" or "shinzui/shikigami")
keiro-destination     = "activity.v1"                   (the contract topic / logical destination)
keiro-event-type      = <envelope.verb>                 (e.g. "intention.declared")
keiro-schema-version  = "1"                              (the activity envelope schema version)
content-type          = "application/json"              (NOTE: no keiro- prefix)
```

**Optional but recommended** (the consumer uses them when present):

```text
keiro-occurred-at     = <envelope.occurred_at RFC3339>
keiro-source-event-id = <envelope.idempotency_key>      (enables PreferSourceEventIdentity if ever chosen)
```

The Kafka **message key** is `<envelope.subject.id>` (subject-keyed, per C3). The record **value**
(`prValue`) is the raw UTF-8 JSON bytes of the Activity Envelope — these become the inbox's
`payloadBytes`, which the handler decodes via `decodeJsonIntegrationEvent` into `ActivityEnvelope`.

### Dedupe policy and offset checkpoint (Open Question 7)

`runInboxTransaction` is called with `PreferIntegrationMessageId` (the default; stable across Kafka
retries). Offsets are committed manually with `commitOffsetMessage` *after* the inbox transaction
commits, never with auto-commit (`noAutoCommit` in the consumer properties). See the Idempotence and
Recovery section for why this is restart-safe.

### Cross-plan integration

- **Consumes IP-1/IP-6 (EP-1, `docs/plans/1-scaffold-agent-schema-loader-and-validate-cli.md`):** the
  `AgentDecl`, `Trigger`, `StreamMatch`, and nine-field `ActivityEnvelope` wire types. This plan does
  not redefine them.
- **Agrees with EP-3 (`docs/plans/3-sink-dispatcher-permission-gate-and-kawa-stub.md`) on IP-6:** the
  exact `keiro-*` header set above. EP-3's `stub-kawa --republish` produces the same set; this plan's
  `publish-fixture` produces it; this plan's consumer reads it. The set must be documented identically
  in both plans.
- **Soft-consumes IP-4 (EP-2, `docs/plans/2-behavior-runner-and-kioku-session-and-memory-integration.md`):**
  a fired trigger would ultimately call `runBehavior`, but until EP-5 wires it, this plan only enqueues
  a `RunJob` and logs the match.
- **Owns IP-7, shared with EP-5 (`docs/plans/5-the-supervised-worker-and-run-orchestration.md`):** this
  plan defines the `shikigami_run_jobs` queue name and the `RunJob` body and *enqueues*; EP-5 *drains*
  and runs the agent. Both document the shape identically.
- **Honors IP-9:** GHC2024, `common` stanza, postpositive qualified imports, `Shikigami.Prelude`
  (no `Data.Generics.Labels`), strict `!` fields, explicit deriving.
