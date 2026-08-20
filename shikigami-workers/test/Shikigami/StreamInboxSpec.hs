module Shikigami.StreamInboxSpec (tests) where

import Data.Aeson qualified as Aeson
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Data.Vector qualified as Vector
import Hasql.Pool qualified as Pool
import Keiro.Inbox (InboxRow (..), InboxStatus (InboxCompleted), KafkaDeliveryRef (..), lookupInbox)
import Keiro.Integration.Event (IntegrationContentType (ApplicationJson), IntegrationEvent (..), encodeJsonIntegrationEvent)
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Pgmq (Message (..), MessageBody (..), ReadMessage (..), dropQueue, readMessage)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), StreamMatch (..), Trigger (..))
import Shikigami.Agent.RunJob (RunJob (..))
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.Trigger.Consumer (RecordDisposition (..), processDecodedActivity)
import Shikigami.Trigger.Enqueue (ensureRunQueue, runQueueName)
import Shikigami.Trigger.Stream (IncludeAgentActors (ExcludeAgentActors))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "StreamInbox"
    [ testCase "matched event atomically records inbox row and enqueues run job" do
        withFixture \appEnv pool -> do
          ensureQueue pool
          hitCount <- newIORef (0 :: Int)
          disposition <-
            processDecodedActivity
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
              assertEqual "stable stream idempotency key" "risk-agent:act_stream_1" idempotencyKey
            other -> assertFailure ("expected one RunJob, got " <> show other)
          inbox <- readInbox appEnv
          assertEqual "completed inbox row" (Just InboxCompleted) (inboxStatus <$> inbox),
      testCase "redelivered event is InboxDuplicate and enqueues nothing" do
        withFixture \appEnv pool -> do
          ensureQueue pool
          first <- processDecodedActivity appEnv ExcludeAgentActors [streamAgent] (const (pure ())) activityEvent (Just deliveryRef)
          second <- processDecodedActivity appEnv ExcludeAgentActors [streamAgent] (const (pure ())) activityEvent (Just deliveryRef)
          assertEqual "first delivery" Enqueued first
          assertEqual "redelivery" Duplicate second
          jobs <- readRunJobs pool
          assertEqual "one queue message" 1 (length jobs),
      testCase "handler failure rolls back both inbox row and message" do
        withFixture \appEnv pool -> do
          ensureQueue pool
          dropped <- Pool.use pool (dropQueue runQueueName)
          case dropped of
            Left err -> assertFailure ("drop run queue failed: " <> show err)
            Right False -> assertFailure "run queue did not exist before rollback test"
            Right True -> pure ()

          failed <- processDecodedActivity appEnv ExcludeAgentActors [streamAgent] (const (pure ())) activityEvent (Just deliveryRef)
          case failed of
            TransientFailure _ -> pure ()
            other -> assertFailure ("expected transient failure, got " <> show other)
          assertEqual "failed transaction left no inbox row" Nothing =<< readInbox appEnv

          ensureQueue pool
          retried <- processDecodedActivity appEnv ExcludeAgentActors [streamAgent] (const (pure ())) activityEvent (Just deliveryRef)
          assertEqual "redelivery succeeds" Enqueued retried
          jobs <- readRunJobs pool
          assertEqual "redelivery enqueued once" 1 (length jobs)
    ]

withFixture :: (AppEnv -> Pool.Pool -> IO a) -> IO a
withFixture use =
  withShikigamiMigratedDatabase \connectionString -> do
    let settings = defaultConnectionSettings connectionString
    withStore settings \store -> do
      tracer <- noopTracer
      let appEnv = AppEnv {connectionSettings = settings, tracer, metrics = Nothing}
      use appEnv (pool store)

ensureQueue :: Pool.Pool -> IO ()
ensureQueue pool = do
  result <- ensureRunQueue pool
  case result of
    Left err -> assertFailure ("ensure run queue failed: " <> show err)
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
    decodeJob payload = case Aeson.fromJSON payload of
      Aeson.Error err -> assertFailure ("invalid RunJob JSON: " <> err)
      Aeson.Success job -> pure job

readInbox :: AppEnv -> IO (Maybe InboxRow)
readInbox appEnv = do
  result <- runAppIO appEnv (lookupInbox "shinzui/test" "stream-message-1")
  case result of
    Left err -> assertFailure ("read inbox failed: " <> show err)
    Right row -> pure row

inboxStatus :: InboxRow -> InboxStatus
inboxStatus InboxRow {status} = status

streamAgent :: AgentDecl
streamAgent =
  AgentDecl
    { name = "risk-agent",
      description = "atomic stream inbox test agent",
      trigger =
        Stream
          { match =
              StreamMatch
                { verb = Just "customer.risk_detected",
                  source = Nothing,
                  subjectType = Just "ticket",
                  verbs = []
                }
          },
      behavior = Deterministic {rule = "test", params = Map.empty},
      sinks = [],
      sanctionedProfile = Nothing
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
    { activityId = "act_stream_1",
      occurredAt = "2026-08-19T00:00:00Z",
      source = "shinzui/test",
      actor = Actor {kind = "service", id = "fixture", session = Nothing},
      subject = Subject {subjectType = "ticket", subjectId = "ticket-1"},
      verb = "customer.risk_detected",
      payload = Aeson.object ["risk" Aeson..= ("high" :: Text)],
      contextRefs = [],
      idempotencyKey = "act_stream_1"
    }

deliveryRef :: KafkaDeliveryRef
deliveryRef = KafkaDeliveryRef {topic = "activity.v1", partition = 0, offset = 42}
