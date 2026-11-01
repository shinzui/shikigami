module Shikigami.StreamInboxSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Data.Vector qualified as Vector
import Hasql.Pool qualified as Pool
import Keiro.Inbox (InboxRow (..), InboxStatus (InboxCompleted), KafkaDeliveryRef (..), lookupInbox)
import Keiro.Inbox.Kafka (KafkaInboundRecord (..))
import Keiro.Integration.Event (IntegrationContentType (ApplicationJson), IntegrationEvent (..), encodeJsonIntegrationEvent, integrationHeaders)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Pgmq (Message (..), MessageBody (..), MessageId (..), QueueName, ReadMessage (..), dropQueue, parseQueueName, readMessage)
import Shibuya.Core.Ack (AckDecision (..))
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), StreamMatch (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.Run.Key (RunKey, parseRunKey)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), runJobWorkflowId)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Directory (DirectoryHandle, Lifecycle (..), PrincipalRecord (..), newDirectoryHandle, refreshDirectory, staticDirectorySource)
import Shikigami.Directory.Store qualified as DirectoryStore
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Trigger.Consumer
  ( DeadLetterId (..),
    DeadLetterRecord (..),
    PayloadEvidence (..),
    RecordDisposition (..),
    ackDecisionFor,
    ensureDeadLetterQueue,
    processActivityRecord,
    processDecodedActivity,
    processDecodedActivityWithDirectory,
    processDecodedIntegrationEvent,
  )
import Shikigami.Trigger.Enqueue (enqueueAddressedRunWithKey, ensureRunQueue, runQueueName)
import Shikigami.Trigger.RequestKey qualified as Addressed
import Shikigami.Trigger.Schedule (parseCron)
import Shikigami.Trigger.Stream (IncludeAgentActors (ExcludeAgentActors))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "StreamInbox"
    [ testCase "addressed caller keys retain separate agent coordinates" do
        withFixture databaseFixture \_appEnv pool -> do
          ensureQueue pool
          let first = fixtureAgentName "first"
              second = fixtureAgentName "second"
          _ <- enqueueAddressedRunWithKey pool (compatibilityIdentity first) first AgentWorkflowRoute (Aeson.object []) (fixtureAddressedKey "shared") >>= either (assertFailure . show) pure
          _ <- enqueueAddressedRunWithKey pool (compatibilityIdentity second) second AgentWorkflowRoute (Aeson.object []) (fixtureAddressedKey "shared") >>= either (assertFailure . show) pure
          _ <- enqueueAddressedRunWithKey pool (compatibilityIdentity first) first AgentWorkflowRoute (Aeson.object []) (fixtureAddressedKey "shared") >>= either (assertFailure . show) pure
          jobs <- readRunJobs pool
          assertEqual "delivery retry retains another delivery of the same logical request" 3 (length jobs)
          assertEqual "independent workflows" 2 (Set.size (Set.fromList (map runJobWorkflowId jobs))),
      testCase "integration keys retain separate agent and opaque message coordinates" do
        withFixture databaseFixture \appEnv pool -> do
          ensureQueue pool
          let first = streamAgent {name = fixtureAgentName "a:b", trigger = Event {eventType = declarationCoordinate ("probe.run")}}
              second = streamAgent {name = fixtureAgentName "a", trigger = Event {eventType = declarationCoordinate ("probe.run")}}
              firstEvent = activityEvent {messageId = "c", eventType = "probe.run"}
              secondEvent = activityEvent {messageId = "b:c", eventType = "probe.run"}
          processDecodedIntegrationEvent appEnv [first] (const (pure ())) firstEvent Nothing >>= assertEqual "first delivery commits" Enqueued
          processDecodedIntegrationEvent appEnv [second] (const (pure ())) secondEvent Nothing >>= assertEqual "second delivery commits" Enqueued
          processDecodedIntegrationEvent appEnv [first] (const (pure ())) firstEvent Nothing >>= assertEqual "native redelivery remains duplicate" Duplicate
          jobs <- readRunJobs pool
          assertEqual "both native inbox deliveries enqueue" 2 (length jobs)
          assertEqual "independent workflows" 2 (Set.size (Set.fromList (map runJobWorkflowId jobs))),
      testCase "matched event atomically records inbox row and enqueues run job" do
        (withFixture databaseFixture) \appEnv pool -> do
          ensureQueue pool
          hitCount <- newIORef (0 :: Int)
          disposition <-
            processDecodedActivity
              Log.silentLogger
              appEnv
              ExcludeAgentActors
              [streamAgent]
              (const (modifyIORef' hitCount (+ 1)))
              activityEvent
              (Just deliveryRef)
          assertEqual "terminal disposition" Enqueued disposition
          assertEqual "reporting hook ran once" 1 =<< readIORef hitCount
          jobs <- readRunJobs pool
          case jobs of
            [RunJob {idempotencyKey}] ->
              assertEqual "stable stream idempotency key" (fixtureRunKey "stream-run-v2:sha256:d5c5840b1bb985d45b79cb5e3034694f28435fd5ce27e2cc39df39e9db25f667") idempotencyKey
            other -> assertFailure ("expected one RunJob, got " <> show other)
          inbox <- readInbox appEnv
          assertEqual "completed inbox row" (Just InboxCompleted) (inboxStatus <$> inbox),
      testCase "redelivered event is InboxDuplicate and enqueues nothing" do
        (withFixture databaseFixture) \appEnv pool -> do
          ensureQueue pool
          first <- processDecodedActivity Log.silentLogger appEnv ExcludeAgentActors [streamAgent] (const (pure ())) activityEvent (Just deliveryRef)
          second <- processDecodedActivity Log.silentLogger appEnv ExcludeAgentActors [streamAgent] (const (pure ())) activityEvent (Just deliveryRef)
          assertEqual "first delivery" Enqueued first
          assertEqual "redelivery" Duplicate second
          jobs <- readRunJobs pool
          assertEqual "one queue message" 1 (length jobs),
      testCase "paused stream match commits skip with inbox and enqueues nothing" do
        (withFixture databaseFixture) \appEnv pool -> do
          ensureQueue pool
          directory <- directoryWith Paused
          first <-
            processDecodedActivityWithDirectory
              Log.silentLogger
              appEnv
              directory
              ExcludeAgentActors
              [streamAgent]
              (const (pure ()))
              activityEvent
              (Just deliveryRef)
          second <-
            processDecodedActivityWithDirectory
              Log.silentLogger
              appEnv
              directory
              ExcludeAgentActors
              [streamAgent]
              (const (pure ()))
              activityEvent
              (Just deliveryRef)
          assertEqual "first refusal commits" Enqueued first
          assertEqual "redelivery is deduped" Duplicate second
          assertEqual "paused stream enqueues no jobs" [] =<< readRunJobs pool
          assertEqual "skip and inbox commit together" (Just InboxCompleted) . fmap inboxStatus =<< readInbox appEnv
          skips <- either (assertFailure . Text.unpack) pure =<< DirectoryStore.listRunSkips pool
          case skips of
            [runSkip] -> do
              assertEqual "principal" (Just "agent_risk") (fmap DirectoryStore.reportedPrincipalClaimText ((.principalId) runSkip))
              assertEqual "trigger boundary" DirectoryStore.TriggerStage ((.stage) runSkip)
              assertEqual "source" "stream" ((.detail) runSkip)
              assertEqual "same key the run would use" (fixtureRunKey "stream-run-v2:sha256:d5c5840b1bb985d45b79cb5e3034694f28435fd5ce27e2cc39df39e9db25f667") ((.idempotencyKey) runSkip)
            other -> assertFailure ("expected one stream skip, got " <> show other),
      testCase "handler failure rolls back both inbox row and message" do
        (withFixture databaseFixture) \appEnv pool -> do
          ensureQueue pool
          dropped <- Pool.use pool (dropQueue runQueueName)
          case dropped of
            Left err -> assertFailure ("drop run queue failed: " <> show err)
            Right False -> assertFailure "run queue did not exist before rollback test"
            Right True -> pure ()

          failed <- processDecodedActivity Log.silentLogger appEnv ExcludeAgentActors [streamAgent] (const (pure ())) activityEvent (Just deliveryRef)
          case failed of
            TransientFailure _ -> pure ()
            other -> assertFailure ("expected transient failure, got " <> show other)
          assertEqual "failed transaction left no inbox row" Nothing =<< readInbox appEnv

          ensureQueue pool
          retried <- processDecodedActivity Log.silentLogger appEnv ExcludeAgentActors [streamAgent] (const (pure ())) activityEvent (Just deliveryRef)
          assertEqual "redelivery succeeds" Enqueued retried
          jobs <- readRunJobs pool
          assertEqual "redelivery enqueued once" 1 (length jobs),
      testCase "store failure yields TransientFailure" do
        tracer <- noopTracer
        let settings = defaultConnectionSettings "host=127.0.0.1 port=1 dbname=unavailable connect_timeout=1"
            appEnv = AppEnv {connectionSettings = settings, tracer, metrics = Nothing, store = Nothing}
        disposition <- processDecodedActivity Log.silentLogger appEnv ExcludeAgentActors [streamAgent] (const (pure ())) activityEvent (Just deliveryRef)
        case disposition of
          TransientFailure _ -> pure ()
          other -> assertFailure ("expected transient store failure, got " <> show other),
      testCase "poison record is durably dead-lettered before terminal ack" do
        (withFixture databaseFixture) \appEnv pool -> do
          ensureDeadQueue pool
          disposition <-
            processActivityRecord
              Log.silentLogger
              appEnv
              deadLetterQueueName
              ExcludeAgentActors
              [streamAgent]
              (const (pure ()))
              poisonRecord
          case disposition of
            PermanentlyDeadLettered _ -> pure ()
            other -> assertFailure ("expected permanent dead letter, got " <> show other)
          assertEqual "poison payload never completed the inbox" Nothing =<< readInbox appEnv
          deadLetters <- readDeadLetters pool
          case deadLetters of
            [DeadLetterRecord {topic, partition, offset, error = failure, evidence = PayloadEvidence {byteCount, sample, truncated}}] -> do
              assertEqual "topic" "activity.v1" topic
              assertEqual "partition" 3 partition
              assertEqual "offset" 99 offset
              assertEqual "full payload byte count" 300 byteCount
              assertEqual "bounded sample" 256 (length sample)
              assertEqual "sample was truncated" True truncated
              assertEqual "decode error is bounded" True (Text.length failure <= 2_048)
            other -> assertFailure ("expected one dead-letter record, got " <> show other),
      testCase "failed dead-letter persistence halts without terminal ack" do
        (withFixture databaseFixture) \appEnv pool -> do
          ensureDeadQueue pool
          dropped <- Pool.use pool (dropQueue deadLetterQueueName)
          case dropped of
            Right True -> pure ()
            other -> assertFailure ("drop dead-letter queue failed: " <> show other)
          disposition <-
            processActivityRecord
              Log.silentLogger
              appEnv
              deadLetterQueueName
              ExcludeAgentActors
              [streamAgent]
              (const (pure ()))
              poisonRecord
          case disposition of
            TransientFailure _ -> pure ()
            other -> assertFailure ("expected transient dead-letter failure, got " <> show other)
          assertEqual "failed dead-letter write never completed the inbox" Nothing =<< readInbox appEnv
          case ackDecisionFor disposition of
            AckHalt _ -> pure ()
            other -> assertFailure ("expected halt decision, got " <> show other),
      testCase "each durable disposition has one terminal framework decision" do
        assertEqual "enqueued commits" AckOk (ackDecisionFor Enqueued)
        assertEqual "duplicate commits" AckOk (ackDecisionFor Duplicate)
        case ackDecisionFor (PermanentlyDeadLettered (QueueDeadLetter (MessageId 1))) of
          AckDeadLetter _ -> pure ()
          other -> assertFailure ("expected dead-letter decision, got " <> show other)
    ]

withFixture :: DatabaseFixture -> (AppEnv -> Pool.Pool -> IO a) -> IO a
withFixture databaseFixture use =
  (withShikigamiFreshDatabase databaseFixture) \connectionString -> do
    let settings = defaultConnectionSettings connectionString
    withStore settings \store -> do
      tracer <- noopTracer
      let appEnv = AppEnv {connectionSettings = settings, tracer, metrics = Nothing, store = Nothing}
      use appEnv (pool store)

ensureQueue :: Pool.Pool -> IO ()
ensureQueue pool = do
  result <- ensureRunQueue pool
  case result of
    Left err -> assertFailure ("ensure run queue failed: " <> show err)
    Right () -> pure ()

ensureDeadQueue :: Pool.Pool -> IO ()
ensureDeadQueue pool = do
  result <- ensureDeadLetterQueue pool deadLetterQueueName
  case result of
    Left err -> assertFailure ("ensure dead-letter queue failed: " <> show err)
    Right () -> pure ()

readRunJobs :: Pool.Pool -> IO [RunJob]
readRunJobs pool = do
  result <-
    Pool.use pool $
      readMessage
        ReadMessage
          { queueName = runQueueName,
            delay = 30,
            batchSize = Just 10,
            conditional = Nothing
          }
  case result of
    Left err -> assertFailure ("read run queue failed: " <> show err)
    Right messages ->
      traverse
        decodeJob
        [ payload
        | Message {body = MessageBody payload} <- Vector.toList messages
        ]
  where
    decodeJob payload = either (assertFailure . ("invalid run envelope: " <>) . show) pure (RunJobs.decodeRunJob payload)

readDeadLetters :: Pool.Pool -> IO [DeadLetterRecord]
readDeadLetters pool = do
  result <-
    Pool.use pool $
      readMessage
        ReadMessage
          { queueName = deadLetterQueueName,
            delay = 30,
            batchSize = Just 10,
            conditional = Nothing
          }
  case result of
    Left err -> assertFailure ("read dead-letter queue failed: " <> show err)
    Right messages ->
      traverse
        decodeDeadLetter
        [ payload
        | Message {body = MessageBody payload} <- Vector.toList messages
        ]
  where
    decodeDeadLetter payload = case Aeson.fromJSON payload of
      Aeson.Error err -> assertFailure ("invalid DeadLetterRecord JSON: " <> err)
      Aeson.Success deadLetter -> pure deadLetter

readInbox :: AppEnv -> IO (Maybe InboxRow)
readInbox appEnv = do
  result <- runAppIO appEnv (lookupInbox "shinzui/test" "stream-message-1")
  case result of
    Left err -> assertFailure ("read inbox failed: " <> show err)
    Right row -> pure row

inboxStatus :: InboxRow -> InboxStatus
inboxStatus InboxRow {status} = status

directoryWith :: Lifecycle -> IO DirectoryHandle
directoryWith lifecycle = do
  directory <-
    newDirectoryHandle
      (staticDirectorySource [PrincipalRecord {principalId = declarationCoordinate ("agent_risk"), handle = declarationCoordinate ("risk-agent"), lifecycle}])
  refreshDirectory directory >>= \case
    Left problem -> assertFailure (Text.unpack problem)
    Right () -> pure directory

streamAgent :: AgentDecl
streamAgent =
  AgentDecl
    { name = fixtureAgentName "risk-agent",
      description = "atomic stream inbox test agent",
      trigger =
        Stream
          { match =
              StreamMatch
                { verb = fmap activityCoordinate (Just "customer.risk_detected"),
                  source = fmap activityCoordinate (Nothing),
                  subjectType = fmap activityCoordinate (Just "ticket"),
                  verbs = map activityCoordinate ([])
                }
          },
      behavior = Deterministic {rule = "test", params = Map.empty},
      sinks = [],
      delegates = map fixtureAgentName [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = agentEnablement (True),
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

activityEvent :: IntegrationEvent
activityEvent =
  encodeJsonIntegrationEvent
    IntegrationEvent
      { messageId = "stream-message-1",
        source = "shinzui/test",
        destination = "activity.v1",
        key = Just "ticket-1",
        eventType = "activity.recorded",
        schemaVersion = 1,
        contentType = ApplicationJson,
        schemaReference = Nothing,
        sourceEventId = Nothing,
        sourceGlobalPosition = Nothing,
        payloadBytes = mempty,
        occurredAt = UTCTime (fromGregorian 2026 8 19) 0,
        causationId = Nothing,
        correlationId = Nothing,
        traceContext = Nothing,
        attributes = Nothing
      }
    sampleActivity

sampleActivity :: ActivityEnvelope
sampleActivity =
  ActivityEnvelope
    { activityId = activityCoordinate ("act_stream_1"),
      occurredAt = activityCoordinate ("2026-08-19T00:00:00Z"),
      source = activityCoordinate ("shinzui/test"),
      actor = Actor {kind = either (error . show) id (parseActorKind ("service")), id = activityCoordinate ("fixture"), session = fmap activityCoordinate (Nothing)},
      subject = Subject {kind = activityCoordinate ("ticket"), subjectId = activityCoordinate ("ticket-1")},
      verb = activityCoordinate ("customer.risk_detected"),
      payload = Aeson.object ["risk" .= ("high" :: Text)],
      contextRefs = [],
      idempotencyKey = activityCoordinate ("act_stream_1")
    }

deliveryRef :: KafkaDeliveryRef
deliveryRef = KafkaDeliveryRef {topic = "activity.v1", partition = 0, offset = 42}

poisonRecord :: KafkaInboundRecord
poisonRecord =
  KafkaInboundRecord
    { topic = "activity.v1",
      partition = 3,
      offset = 99,
      key = Just "ticket-poison",
      payload = ByteString.replicate 300 255,
      headers = integrationHeaders activityEvent,
      receivedAt = UTCTime (fromGregorian 2026 8 19) 0
    }

deadLetterQueueName :: QueueName
deadLetterQueueName =
  case parseQueueName "shikigami_stream_dead_letters_test" of
    Left err -> Prelude.error (show err)
    Right queue -> queue

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureRunKey :: Text -> RunKey
fixtureRunKey = either (error . show) id . parseRunKey

fixtureAddressedKey :: Text -> Addressed.RequestKey
fixtureAddressedKey = either (error . show) id . Addressed.parseRequestKey
