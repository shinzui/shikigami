module Shikigami.StreamInboxSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, getCurrentTime)
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Keiro.Inbox (InboxRow (..), InboxStatus (InboxCompleted), KafkaDeliveryRef (..), lookupInbox)
import Keiro.Inbox.Kafka (KafkaInboundRecord (..))
import Keiro.Integration.Event (IntegrationContentType (ApplicationJson), IntegrationEvent (..), encodeJsonIntegrationEvent, integrationHeaders)
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Pgmq (Message (..), MessageBody (..), MessageId (..), QueueName, ReadMessage (..), dropQueue, parseQueueName, readMessage)
import Shibuya.Core.Ack (AckDecision (..))
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), IdentityDecl (..), StreamMatch (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.Run.Key (RunKey, parseRunKey)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), runJobWorkflowId)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Directory (DirectoryHandle, Lifecycle (..), PrincipalRecord (..), newDirectoryHandle, refreshDirectory, staticDirectorySource)
import Shikigami.Directory.Store qualified as DirectoryStore
import Shikigami.Execution.Identity (executionRootIdText)
import Shikigami.Execution.Quantity (parseResourceAmount)
import Shikigami.Execution.Resources (Dimension (..), Envelope (..), Limit (..))
import Shikigami.Initiative.Settings (InitiativeSettings)
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Trigger.Consumer
  ( DeadLetterId (..),
    DeadLetterRecord (..),
    PayloadEvidence (..),
    RecordDisposition (..),
    StreamHit,
    ackDecisionFor,
    ensureDeadLetterQueue,
    processActivityRecord,
    processDecodedActivity,
    processDecodedActivityObserving,
    processDecodedActivityWithDirectory,
    processDecodedIntegrationEvent,
  )
import Shikigami.Trigger.Enqueue (enqueueAddressedRunWithKey, ensureRunQueue, runQueueName)
import Shikigami.Trigger.RequestKey qualified as Addressed
import Shikigami.Trigger.Schedule (parseCron)
import Shikigami.Trigger.Stream (IncludeAgentActors (ExcludeAgentActors, IncludeAgentActors))
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
      testCase "unrelated chatter from an observer commits one bounded skip and no job" do
        withFixture databaseFixture \appEnv pool -> do
          ensureQueue pool
          directory <- observerDirectory
          hits <- newIORef (0 :: Int)
          disposition <- observed appEnv directory (const (modifyIORef' hits (+ 1))) (chatEvent "chat-1" "act-chat-1" (Aeson.object ["text" .= ("too short" :: Text)]))
          assertEqual "the skip is a durable disposition" Enqueued disposition
          assertEqual "nothing was matched for a run" 0 =<< readIORef hits
          assertEqual "no job" [] =<< readRunJobs pool
          assertEqual "skip row" [("act-chat-1", "skipped", Just "excerpt-too-short", Just "chat-subject", Nothing)] =<< readCandidates pool
          assertEqual "no root origin" 0 =<< countRows pool "shikigami.execution_root_origins",
      testCase "an agent-authored envelope is a bounded skip when the guard is lifted and invisible when it is not" do
        withFixture databaseFixture \appEnv pool -> do
          ensureQueue pool
          directory <- observerDirectory
          let event = chatEventBy agentActorFixture "fixture/chat" "chat-2" "act-chat-2" (Aeson.object ["text" .= longReport])
          _ <- observed appEnv directory (const (pure ())) event
          assertEqual "the feedback guard matches nothing" [] =<< readCandidates pool
          assertEqual "lifted guard" Enqueued =<< processDecodedActivityObserving Log.silentLogger appEnv directory (Just observerSettings) (\_ _ -> pure ()) IncludeAgentActors [observerAgent] (const (pure ())) event {messageId = "chat-2b"} (Just deliveryRef)
          assertEqual "no job" [] =<< readRunJobs pool
          assertEqual "agent skip without a subject" [("act-chat-2", "skipped", Just "agent-actor", Nothing, Nothing)] =<< readCandidates pool,
      testCase "a source no adapter recognizes is a bounded skip without a subject" do
        withFixture databaseFixture \appEnv pool -> do
          ensureQueue pool
          directory <- observerDirectory
          let anySource = observerAgent {trigger = Stream {match = StreamMatch {verb = Nothing, source = Nothing, subjectType = Nothing, verbs = []}}}
          assertEqual "committed" Enqueued =<< processDecodedActivityObserving Log.silentLogger appEnv directory (Just observerSettings) (\_ _ -> pure ()) ExcludeAgentActors [anySource] (const (pure ())) (chatEventBy humanActorFixture "external/slack" "chat-6" "act-chat-6" (Aeson.object ["text" .= longReport])) (Just deliveryRef)
          assertEqual "no job" [] =<< readRunJobs pool
          assertEqual "skip" [("act-chat-6", "skipped", Just "unsupported-source", Nothing, Nothing)] =<< readCandidates pool,
      testCase "a bug report from an observer commits one inbox row, root origin, root, candidate and job together" do
        withFixture databaseFixture \appEnv pool -> do
          ensureQueue pool
          directory <- observerDirectory
          hits <- newIORef (0 :: Int)
          let event = chatEvent "chat-3" "act-chat-3" (Aeson.object ["text" .= longReport])
          disposition <- observed appEnv directory (const (modifyIORef' hits (+ 1))) event
          assertEqual "committed" Enqueued disposition
          assertEqual "hook ran once" 1 =<< readIORef hits
          jobs <- readRunJobs pool
          job <- case jobs of
            [only] -> pure only
            other -> assertFailure ("expected one job, got " <> show (length other))
          root <- maybe (assertFailure "the job carries no root") pure job.executionRootId
          assertEqual "origin row names the job's root" [executionRootIdText root] =<< readOriginRoots pool
          (limits, cutoffAt) <- readRootEnvelope pool (executionRootIdText root)
          assertEqual "the root has the allowance's limits" (Map.fromList [(ActiveWork, Limited (either (error . show) id (parseResourceAmount 1))), (ModelAttempts, Limited (either (error . show) id (parseResourceAmount 1))), (Tokens, ExplicitlyUnbounded), (CostMicroUsd, ExplicitlyUnbounded)]) limits
          now <- getCurrentTime
          assertEqual "the cutoff is the receipt instant plus the evaluation window" True (cutoffAt > addUTCTime 3000 now && cutoffAt <= addUTCTime 3600 now)
          assertEqual "candidate row" [("act-chat-3", "evaluating", Nothing, Just "chat-subject", Just (workflowText (runJobWorkflowId job)))] =<< readCandidates pool
          assertEqual "inbox row" (Just InboxCompleted) . fmap inboxStatus =<< readInboxFor appEnv "chat-3",
      testCase "a redelivery under the same message is a duplicate; under another message it starts nothing new" do
        withFixture databaseFixture \appEnv pool -> do
          ensureQueue pool
          directory <- observerDirectory
          let event = chatEvent "chat-4" "act-chat-4" (Aeson.object ["text" .= longReport])
          assertEqual "first" Enqueued =<< observed appEnv directory (const (pure ())) event
          assertEqual "same message" Duplicate =<< observed appEnv directory (const (pure ())) event
          assertEqual "same activity, new message" Enqueued =<< observed appEnv directory (const (pure ())) (chatEvent "chat-4b" "act-chat-4" (Aeson.object ["text" .= longReport]))
          assertEqual "one job" 1 . length =<< readRunJobs pool
          assertEqual "one root origin" 1 =<< countRows pool "shikigami.execution_root_origins"
          assertEqual "one candidate" 1 =<< countRows pool "shikigami.initiative_candidates",
      testCase "a store failure after the root insert rolls everything back and redelivery recovers" do
        withFixture databaseFixture \appEnv pool -> do
          ensureQueue pool
          directory <- observerDirectory
          dropped <- Pool.use pool (dropQueue runQueueName)
          assertEqual "queue dropped" (Right True) (either (Left . show) Right dropped)
          let event = chatEvent "chat-5" "act-chat-5" (Aeson.object ["text" .= longReport])
          failed <- observed appEnv directory (const (pure ())) event
          case failed of
            TransientFailure _ -> pure ()
            other -> assertFailure ("expected transient failure, got " <> show other)
          assertEqual "no inbox row" Nothing =<< readInboxFor appEnv "chat-5"
          assertEqual "no root origin" 0 =<< countRows pool "shikigami.execution_root_origins"
          assertEqual "no root" 0 =<< countRows pool "shikigami.execution_roots"
          assertEqual "no candidate" 0 =<< countRows pool "shikigami.initiative_candidates"
          ensureQueue pool
          assertEqual "redelivery commits" Enqueued =<< observed appEnv directory (const (pure ())) event
          assertEqual "one job" 1 . length =<< readRunJobs pool,
      testCase "an agent without an allowance keeps its exact job bytes even with settings present" do
        withFixture databaseFixture \appEnv pool -> do
          ensureQueue pool
          directory <- directoryWith Active
          assertEqual "committed" Enqueued =<< processDecodedActivityObserving Log.silentLogger appEnv directory (Just observerSettings) (\_ _ -> pure ()) ExcludeAgentActors [streamAgent {identity = Just IdentityDecl {principal = declarationCoordinate "agent_risk"}}] (const (pure ())) activityEvent (Just deliveryRef)
          jobs <- readRunJobs pool
          assertEqual "no root" [Nothing] (map (.executionRootId) jobs)
          assertEqual "no candidate" 0 =<< countRows pool "shikigami.initiative_candidates",
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

observed :: AppEnv -> DirectoryHandle -> (StreamHit -> IO ()) -> IntegrationEvent -> IO RecordDisposition
observed appEnv directory onHit event =
  processDecodedActivityObserving Log.silentLogger appEnv directory (Just observerSettings) (\_ _ -> pure ()) ExcludeAgentActors [observerAgent] onHit event (Just deliveryRef)

observerDirectory :: IO DirectoryHandle
observerDirectory = do
  directory <- newDirectoryHandle (staticDirectorySource [PrincipalRecord {principalId = declarationCoordinate "agent_proposer", handle = declarationCoordinate "proposer", lifecycle = Active}])
  refreshDirectory directory >>= \case
    Left problem -> assertFailure (Text.unpack problem)
    Right () -> pure directory

observerAgent :: AgentDecl
observerAgent =
  streamAgent
    { name = fixtureAgentName "proposer",
      trigger = Stream {match = StreamMatch {verb = Nothing, source = Just (activityCoordinate "fixture/chat"), subjectType = Nothing, verbs = []}},
      behavior = Flow {name = declarationCoordinate "propose-work"},
      identity = Just IdentityDecl {principal = declarationCoordinate "agent_proposer"}
    }

observerSettings :: InitiativeSettings
observerSettings =
  either error id $
    Aeson.eitherDecode $
      Aeson.encode $
        Aeson.object
          [ "observers"
              .= [ Aeson.object
                     [ "principal" .= ("agent_proposer" :: Text),
                       "sources" .= (["chat-fixture"] :: [Text]),
                       "minimumExcerptLength" .= (20 :: Int),
                       "evaluation" .= Aeson.object ["limits" .= Aeson.object ["ActiveWork" .= (1 :: Int), "ModelAttempts" .= (1 :: Int), "Tokens" .= ("unbounded" :: Text), "CostMicroUsd" .= ("unbounded" :: Text)], "cutoff" .= (3600 :: Int)],
                       "evaluationsPerWindow" .= (10 :: Int),
                       "proposalsPerWindow" .= (5 :: Int),
                       "notificationsPerWindow" .= (5 :: Int),
                       "window" .= (3600 :: Int),
                       "proposalExpiry" .= (86400 :: Int),
                       "rejectionSuppression" .= (604800 :: Int),
                       "notices" .= Aeson.object ["kizashiRecipient" .= ("recipient_ops" :: Text)]
                     ]
                 ]
          ]

longReport :: Text
longReport = "Double-clicking checkout charges the card twice on every attempt"

humanActorFixture :: Actor
humanActorFixture = Actor {kind = HumanActor, id = activityCoordinate "customer-1", session = Nothing}

agentActorFixture :: Actor
agentActorFixture = Actor {kind = AgentActor, id = activityCoordinate "agent_other", session = Nothing}

chatEvent :: Text -> Text -> Aeson.Value -> IntegrationEvent
chatEvent = chatEventBy humanActorFixture "fixture/chat"

chatEventBy :: Actor -> Text -> Text -> Text -> Aeson.Value -> IntegrationEvent
chatEventBy actor source message activity payload =
  encodeJsonIntegrationEvent
    IntegrationEvent
      { messageId = message,
        source = "shinzui/test",
        destination = "activity.v1",
        key = Just "chat-subject",
        eventType = "activity.recorded",
        schemaVersion = 1,
        contentType = ApplicationJson,
        schemaReference = Nothing,
        sourceEventId = Nothing,
        sourceGlobalPosition = Nothing,
        payloadBytes = mempty,
        occurredAt = UTCTime (fromGregorian 2026 11 4) 0,
        causationId = Nothing,
        correlationId = Nothing,
        traceContext = Nothing,
        attributes = Nothing
      }
    ActivityEnvelope
      { activityId = activityCoordinate activity,
        occurredAt = activityCoordinate "2026-11-04T00:00:00Z",
        source = activityCoordinate source,
        actor,
        subject = Subject {kind = activityCoordinate "chat", subjectId = activityCoordinate "chat-subject"},
        verb = activityCoordinate "message.created",
        payload,
        contextRefs = [],
        idempotencyKey = activityCoordinate activity
      }

workflowText :: WorkflowId -> Text
workflowText (WorkflowId value) = value

readCandidates :: Pool.Pool -> IO [(Text, Text, Maybe Text, Maybe Text, Maybe Text)]
readCandidates pool =
  Pool.use pool (Session.statement () statement) >>= either (assertFailure . show) pure
  where
    statement =
      preparable
        "SELECT activity_id,verdict,skip_reason,subject_id,run_workflow_id FROM shikigami.initiative_candidates ORDER BY activity_id"
        E.noParams
        (D.rowList ((,,,,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text) <*> D.column (D.nullable D.text) <*> D.column (D.nullable D.text) <*> D.column (D.nullable D.text)))

countRows :: Pool.Pool -> Text -> IO Int
countRows pool table =
  Pool.use pool (Session.statement () statement) >>= either (assertFailure . show) (pure . fromIntegral)
  where
    statement = preparable ("SELECT count(*) FROM " <> table) E.noParams (D.singleRow (D.column (D.nonNullable D.int8)))

readOriginRoots :: Pool.Pool -> IO [Text]
readOriginRoots pool =
  Pool.use pool (Session.statement () statement) >>= either (assertFailure . show) pure
  where
    statement = preparable "SELECT root_id FROM shikigami.execution_root_origins" E.noParams (D.rowList (D.column (D.nonNullable D.text)))

readRootEnvelope :: Pool.Pool -> Text -> IO (Map.Map Dimension Limit, UTCTime)
readRootEnvelope pool root = do
  binding <- Pool.use pool (Session.statement root statement) >>= either (assertFailure . show) pure
  case Aeson.fromJSON binding of
    Aeson.Success Envelope {limits, cutoff} -> pure (limits, cutoff)
    Aeson.Error problem -> assertFailure problem
  where
    statement =
      preparable
        "SELECT binding->'envelope' FROM shikigami.execution_root_origins WHERE root_id=$1"
        (E.param (E.nonNullable E.text))
        (D.singleRow (D.column (D.nonNullable D.jsonb)))

readInboxFor :: AppEnv -> Text -> IO (Maybe InboxRow)
readInboxFor appEnv message = do
  result <- runAppIO appEnv (lookupInbox "shinzui/test" message)
  case result of
    Left err -> assertFailure ("read inbox failed: " <> show err)
    Right row -> pure row

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
