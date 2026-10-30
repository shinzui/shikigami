{-# LANGUAGE TypeApplications #-}

-- | Durable Kafka consumers for stream and public integration-event triggers.
-- Shibuya owns polling and offset storage; application code establishes one of
-- the explicit durable dispositions below and returns exactly one ack decision.
module Shikigami.Trigger.Consumer
  ( OnSupervisor,
    StreamConfig (..),
    StreamHit (..),
    EventHit (..),
    DeadLetterId (..),
    PayloadEvidence (..),
    DeadLetterRecord (..),
    RecordDisposition (..),
    subscribeActivityStream,
    subscribeIntegrationEventStream,
    processActivityRecord,
    processActivityRecordWithDirectory,
    processIntegrationEventRecord,
    processIntegrationEventRecordWithDirectory,
    processDecodedActivity,
    processDecodedActivityWithDirectory,
    processDecodedIntegrationEvent,
    processDecodedIntegrationEventWithDirectory,
    ackDecisionFor,
    kafkaReconnectAllowed,
    ensureDeadLetterQueue,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception qualified as Exception
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Text.Read qualified as TextRead
import Data.Word (Word8)
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Exception qualified as EffException
import Hasql.Pool (Pool, UsageError)
import Hasql.Pool qualified as Pool
import Hasql.Transaction qualified as Tx
import Kafka.Consumer
  ( ConsumerGroupId (..),
    OffsetReset (..),
    RdKafkaRespErrT (RdKafkaRespErrAuthentication, RdKafkaRespErrFatal, RdKafkaRespErrSaslAuthenticationFailed),
    TopicName (..),
    brokersList,
    groupId,
    noAutoOffsetStore,
    offsetReset,
    topics,
  )
import Kafka.Effectful (KafkaError (..), runKafkaConsumer)
import Kafka.Types (BrokerAddress (..))
import Keiro.Inbox (runInboxTransaction)
import Keiro.Inbox.Kafka (KafkaInboundRecord (..), integrationEventFromKafka)
import Keiro.Inbox.Types (InboxDedupePolicy (PreferIntegrationMessageId), InboxResult (..), KafkaDeliveryRef (..))
import Keiro.Integration.Event (IntegrationEvent, decodeJsonIntegrationEvent)
import Kiroku.Store.Notification (NotifierStartError)
import Kiroku.Store.Transaction (runTransaction)
import Pgmq (MessageBody (..), MessageId (..), QueueName, SendMessage (..), createQueue)
import Pgmq.Hasql.Statements.Message qualified as PgmqStatements
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.App qualified as Shibuya
import Shibuya.Core.Ack (AckDecision (..), DeadLetterCode, DeadLetterReason (ApplicationFailure), HaltReason (..), mkDeadLetterCode)
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..))
import Shibuya.Policy (Concurrency (Serial), OrderingPolicy (StrictInOrder))
import Shibuya.Telemetry.Effect (runTracing)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..), StreamMatch, Trigger (..))
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (AgentIdentity (..), compatibilityIdentity, mkAgentPrincipal)
import Shikigami.Agent.Run.Key (RunKey (..), runKeyText)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (TriggeredByEvent))
import Shikigami.Agent.RunJob qualified as RunJob
import Shikigami.App (AppEnv (..), runAppIO)
import Shikigami.Directory qualified as Directory
import Shikigami.Directory.Store (RunSkip (..), SkipStage (TriggerStage), recordRunSkipTx)
import Shikigami.Integration.Danwa qualified as Danwa
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Telemetry.Metrics (ShikigamiMetrics, recordConsumerRecord)
import Shikigami.Trigger.Enqueue (enqueueRunJobTx, envelopeOccurredAt, runJobFromEnvelopeWithIdentity)
import Shikigami.Trigger.Stream (IncludeAgentActors, matchesStreamWith)
import Shikigami.Workers.ConsumerApp (consumerAppConfig, withConsumerApp)

-- | Connection and durable poison-record target for one Kafka subscription.
data StreamConfig = StreamConfig
  { broker :: !Text,
    topic :: !Text,
    consumerGroupId :: !Text,
    deadLetterQueue :: !QueueName
  }
  deriving stock (Eq, Show)

data StreamHit = StreamHit
  { agentName :: !Text,
    envelope :: !ActivityEnvelope
  }
  deriving stock (Eq, Show)

data EventHit = EventHit
  { agentName :: !Text,
    eventType :: !Text,
    integrationMessageId :: !Text,
    payload :: !Value
  }
  deriving stock (Eq, Show)

newtype DeadLetterId = DeadLetterId Text
  deriving stock (Eq, Show)

-- | Bounded raw evidence. The full poison payload never enters the queue.
data PayloadEvidence = PayloadEvidence
  { byteCount :: !Int,
    sample :: ![Word8],
    truncated :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Recoverable operator evidence for an unprocessable Kafka delivery.
data DeadLetterRecord = DeadLetterRecord
  { topic :: !Text,
    partition :: !Int64,
    offset :: !Int64,
    error :: !Text,
    evidence :: !PayloadEvidence,
    recordedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data RecordDisposition
  = Enqueued
  | Duplicate
  | PermanentlyDeadLettered !DeadLetterId
  | TransientFailure !Text
  deriving stock (Eq, Show)

-- | Told which shibuya supervisor is currently driving this consumer, and
-- 'Nothing' whenever it is between connections.
--
-- The consumer reports what it has rather than what that means: this module owns
-- the acknowledgement boundary and should not also own health vocabulary. The
-- caller decides that a live supervisor's own processor state is the honest
-- liveness signal, and that a consumer in backoff is alive and retrying.
--
-- 'Nothing' arrives before each connection attempt, including the first, so a
-- consumer that can never reach its broker still says so on every attempt
-- instead of falling silent.
type OnSupervisor = Maybe (Shibuya.Master, Shibuya.ProcessorId) -> IO ()

-- | Subscribe to @activity.v1@ through the serial Shibuya Kafka adapter.
subscribeActivityStream :: Log.Logger -> OnSupervisor -> ShikigamiMetrics -> AppEnv -> Directory.DirectoryHandle -> StreamConfig -> IncludeAgentActors -> [AgentDecl] -> (StreamHit -> IO ()) -> IO ()
subscribeActivityStream logger onSupervisor metrics appEnv directory config@StreamConfig {deadLetterQueue} include agents onHit =
  runSubscription logger onSupervisor "stream" metrics appEnv config $ processActivityRecordWithDirectory logger appEnv directory deadLetterQueue include agents onHit

-- | Subscribe to a public integration-event topic through the same durable
-- acknowledgement boundary.
subscribeIntegrationEventStream :: Log.Logger -> OnSupervisor -> ShikigamiMetrics -> AppEnv -> Directory.DirectoryHandle -> StreamConfig -> [AgentDecl] -> (EventHit -> IO ()) -> IO ()
subscribeIntegrationEventStream logger onSupervisor metrics appEnv directory config@StreamConfig {deadLetterQueue} agents onHit =
  runSubscription logger onSupervisor "events" metrics appEnv config $ processIntegrationEventRecordWithDirectory logger appEnv directory deadLetterQueue agents onHit

runSubscription ::
  Log.Logger ->
  OnSupervisor ->
  Text ->
  ShikigamiMetrics ->
  AppEnv ->
  StreamConfig ->
  (KafkaInboundRecord -> IO RecordDisposition) ->
  IO ()
runSubscription logger onSupervisor prefix metrics AppEnv {tracer} StreamConfig {broker = streamBroker, topic = streamTopic, consumerGroupId = streamGroup} processRecord =
  permanentFailureCode `seq` reconnect 1
  where
    reconnect backoffSeconds = do
      -- Announced before every attempt, so the stretch between a lost
      -- connection and the next supervisor is visibly a retrying loop rather
      -- than a silent one.
      onSupervisor Nothing
      let props =
            brokersList [BrokerAddress streamBroker]
              <> groupId (ConsumerGroupId streamGroup)
              <> noAutoOffsetStore
          sub = topics [TopicName streamTopic] <> offsetReset Earliest
      result <-
        runEff . runErrorNoCallStack @KafkaError . runTracing tracer $
          runKafkaConsumer props sub do
            adapter <- kafkaAdapter (defaultConfig [TopicName streamTopic])
            programmingFailure <- liftIO (newIORef Nothing)
            let handler message = do
                  attempt <-
                    liftIO . trySynchronous $ do
                      disposition <- processKafkaMessage streamTopic metrics processRecord message
                      logDisposition logger prefix disposition
                      pure disposition
                  case attempt of
                    Left err -> do
                      liftIO (writeIORef programmingFailure (Just err))
                      pure (AckHalt (HaltFatal (Text.take errorLimit (Text.pack (show err)))))
                    Right disposition -> pure (ackDecisionFor disposition)
                processor =
                  Shibuya.QueueProcessor
                    { adapter,
                      handler,
                      ordering = StrictInOrder,
                      concurrency = Serial
                    }
            appResult <-
              ( withConsumerApp consumerAppConfig [(Shibuya.ProcessorId streamTopic, processor)] \app -> do
                  liftIO (onSupervisor (Just (Shibuya.getAppMaster app, Shibuya.ProcessorId streamTopic)))
                  Shibuya.waitApp app
                  liftIO (readIORef programmingFailure)
              )
                `EffException.finally` liftIO (onSupervisor Nothing)
            pure appResult
      case result of
        Left err | not (kafkaReconnectAllowed err) -> fail (Text.unpack (prefix <> " consumer refused a deterministic configuration, authentication or fatal error"))
        Left err -> retryAfter backoffSeconds (Text.pack (show err)) (min 30 (backoffSeconds * 2))
        Right (Left appError) -> fail (Text.unpack (prefix <> " consumer configuration failed: " <> Text.pack (show appError)))
        Right (Right (Just programmingFailure)) -> Exception.throwIO programmingFailure
        Right (Right Nothing) -> retryAfter 1 "ordered processor halted without committing its current record" 1

    retryAfter seconds reason next = do
      Log.logError
        logger
        (prefix <> ".consumer.reconnecting")
        [ "delay_seconds" Aeson..= seconds,
          "reason" Aeson..= reason
        ]
      threadDelay (seconds * 1_000_000)
      reconnect next

-- | Recreating a connection cannot repair invalid configuration or credentials.
-- A fatal client failure must reach the process supervisor rather than loop
-- forever alongside a healthy probe listener. Broker outages retain backoff.
kafkaReconnectAllowed :: KafkaError -> Bool
kafkaReconnectAllowed = \case
  KafkaBadConfiguration -> False
  KafkaBadSpecification _ -> False
  KafkaResponseError RdKafkaRespErrAuthentication -> False
  KafkaResponseError RdKafkaRespErrSaslAuthenticationFailed -> False
  KafkaResponseError RdKafkaRespErrFatal -> False
  _ -> True

trySynchronous :: IO value -> IO (Either Exception.SomeException value)
trySynchronous action =
  Exception.try action >>= \case
    Left err
      | Just (_ :: Exception.SomeAsyncException) <- Exception.fromException err -> Exception.throwIO err
      | otherwise -> pure (Left err)
    Right value -> pure (Right value)

processKafkaMessage :: Text -> ShikigamiMetrics -> (KafkaInboundRecord -> IO RecordDisposition) -> Message es (Maybe ByteString) -> IO RecordDisposition
processKafkaMessage streamTopic metrics processRecord Message {envelope = Envelope {cursor, partition, headers, payload}} = do
  now <- getCurrentTime
  case do
    recordPartition <- maybe (Left "Kafka envelope has no partition") parsePartition partition
    recordOffset <- maybe (Left "Kafka envelope has no cursor") parseCursor cursor
    pure
      KafkaInboundRecord
        { topic = streamTopic,
          partition = recordPartition,
          offset = recordOffset,
          -- Shibuya Kafka adapter 0.9 does not surface ConsumerRecord.crKey.
          -- Shikigami's inbox and matchers do not consult the integration key.
          key = Nothing,
          payload = fromMaybe mempty payload,
          headers = decodeHeaders (fromMaybe [] headers),
          receivedAt = now
        } of
    Left err -> pure (TransientFailure err)
    Right record -> do
      recordConsumerRecord metrics streamTopic
      processRecord record

parsePartition :: Text -> Either Text Int64
parsePartition = parseSignedDecimal "Kafka partition"

parseCursor :: Cursor -> Either Text Int64
parseCursor = \case
  CursorInt value -> Right (fromIntegral value)
  CursorText value -> parseSignedDecimal "Kafka cursor" value

parseSignedDecimal :: Text -> Text -> Either Text Int64
parseSignedDecimal label value =
  case TextRead.signed TextRead.decimal value of
    Right (number, rest) | Text.null rest -> Right number
    _ -> Left (label <> " is not a signed decimal: " <> Text.take 128 value)

decodeHeaders :: [(ByteString, ByteString)] -> [(Text, Text)]
decodeHeaders = fmap (bimap decode decode)
  where
    decode = TE.decodeUtf8With lenientDecode

-- | Process a raw activity delivery. Any envelope or payload decode failure is
-- persisted before a terminal disposition is returned.
processActivityRecord ::
  Log.Logger ->
  AppEnv ->
  QueueName ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  KafkaInboundRecord ->
  IO RecordDisposition
processActivityRecord logger appEnv =
  processActivityRecordWithDirectory logger appEnv Directory.disabledDirectoryHandle

processActivityRecordWithDirectory ::
  Log.Logger ->
  AppEnv ->
  Directory.DirectoryHandle ->
  QueueName ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  KafkaInboundRecord ->
  IO RecordDisposition
processActivityRecordWithDirectory logger appEnv directory queue include agents onHit record =
  case integrationEventFromKafka record of
    Left err -> persistPoison appEnv queue record (Text.pack (show err))
    Right (event, delivery) ->
      case decodeJsonIntegrationEvent event of
        Left err -> persistPoison appEnv queue record (Text.pack (show err))
        Right activity -> processActivity logger appEnv directory include agents onHit event (Just delivery) activity

-- | Process one raw public integration-event delivery.
processIntegrationEventRecord ::
  AppEnv ->
  QueueName ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  KafkaInboundRecord ->
  IO RecordDisposition
processIntegrationEventRecord appEnv =
  processIntegrationEventRecordWithDirectory Log.silentLogger appEnv Directory.disabledDirectoryHandle

processIntegrationEventRecordWithDirectory ::
  Log.Logger ->
  AppEnv ->
  Directory.DirectoryHandle ->
  QueueName ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  KafkaInboundRecord ->
  IO RecordDisposition
processIntegrationEventRecordWithDirectory logger appEnv directory queue agents onHit record =
  case integrationEventFromKafka record of
    Left err -> persistPoison appEnv queue record (Text.pack (show err))
    Right (event, delivery) ->
      case decodeJsonIntegrationEvent event of
        Left err -> persistPoison appEnv queue record (Text.pack (show err))
        Right payloadValue -> processIntegrationEvent logger appEnv directory agents onHit event (Just delivery) payloadValue

-- | Process an already decoded transport event. An invalid activity payload is
-- transient here because this broker-free entry point has no raw delivery to
-- preserve; the raw-record entry point above durably dead-letters it.
processDecodedActivity ::
  Log.Logger ->
  AppEnv ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  IO RecordDisposition
processDecodedActivity logger appEnv =
  processDecodedActivityWithDirectory logger appEnv Directory.disabledDirectoryHandle

processDecodedActivityWithDirectory ::
  Log.Logger ->
  AppEnv ->
  Directory.DirectoryHandle ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  IO RecordDisposition
processDecodedActivityWithDirectory logger appEnv directory include agents onHit event kafka =
  case decodeJsonIntegrationEvent event of
    Left err -> pure (TransientFailure (Text.pack (show err)))
    Right activity -> processActivity logger appEnv directory include agents onHit event kafka activity

-- | When the envelope says it happened, or this moment plus a line saying the
-- envelope did not say.
--
-- An unparseable @occurredAt@ used to become @1970-01-01T00:00:00Z@ silently,
-- which backdated the run's whole durable record by decades. Substituting the
-- receive time is the honest fallback — it is what the event-inbox path already
-- does with its @receivedAt@ — and the log line is what stops the substitution
-- from being another silence.
resolveOccurredAt :: Log.Logger -> ActivityEnvelope -> IO UTCTime
resolveOccurredAt logger activity =
  case envelopeOccurredAt activity of
    Just parsed -> pure parsed
    Nothing -> do
      now <- getCurrentTime
      Log.logError
        logger
        "stream.envelope.occurred_at_invalid"
        [ "activity_id" Aeson..= (activity ^. #activityId),
          "occurred_at" Aeson..= (activity ^. #occurredAt),
          "substituted" Aeson..= now
        ]
      pure now

processActivity ::
  Log.Logger ->
  AppEnv ->
  Directory.DirectoryHandle ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  ActivityEnvelope ->
  IO RecordDisposition
processActivity logger appEnv directory include agents onHit event kafka activity = do
  -- Resolved before the transaction opens, because deciding it may need a clock
  -- and a log line and the handler runs inside Hasql.
  resolvedOccurredAt <- resolveOccurredAt logger activity
  prepared <- prepareActivityHits directory resolvedOccurredAt include agents activity
  attempt <-
    Exception.try @NotifierStartError $
      runAppIO appEnv $
        runInboxTransaction Nothing PreferIntegrationMessageId event kafka (inboxHandler prepared)
  case attempt of
    Left storeStartupError -> pure (TransientFailure (Text.pack (show storeStartupError)))
    Right result -> classifyInboxResult event (reportCommitted logger "stream" onHit) result

-- | Broker-free transactional entry point for public integration events.
processDecodedIntegrationEvent ::
  AppEnv ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  IO RecordDisposition
processDecodedIntegrationEvent appEnv =
  processDecodedIntegrationEventWithDirectory Log.silentLogger appEnv Directory.disabledDirectoryHandle

processDecodedIntegrationEventWithDirectory ::
  Log.Logger ->
  AppEnv ->
  Directory.DirectoryHandle ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  IO RecordDisposition
processDecodedIntegrationEventWithDirectory logger appEnv directory agents onHit event kafka =
  case decodeJsonIntegrationEvent event of
    Left err -> pure (TransientFailure (Text.pack (show err)))
    Right payloadValue -> processIntegrationEvent logger appEnv directory agents onHit event kafka payloadValue

processIntegrationEvent ::
  Log.Logger ->
  AppEnv ->
  Directory.DirectoryHandle ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  Value ->
  IO RecordDisposition
processIntegrationEvent logger appEnv directory agents onHit event kafka payloadValue = do
  receivedAt <- getCurrentTime
  prepared <- prepareEventHits directory receivedAt agents payloadValue event
  attempt <-
    Exception.try @NotifierStartError $
      runAppIO appEnv $
        runInboxTransaction Nothing PreferIntegrationMessageId event kafka (eventInboxHandler prepared)
  case attempt of
    Left storeStartupError -> pure (TransientFailure (Text.pack (show storeStartupError)))
    Right result -> classifyInboxResult event (reportCommitted logger "events" onHit) result

classifyInboxResult ::
  (Show storeError, Show inboxError) =>
  IntegrationEvent ->
  (hit -> IO ()) ->
  Either storeError (Either inboxError (InboxResult [hit])) ->
  IO RecordDisposition
classifyInboxResult event onHit = \case
  Right (Right (InboxProcessed hits)) -> traverse_ onHit hits >> pure Enqueued
  Right (Right InboxDuplicate) -> pure Duplicate
  Right (Right InboxInProgress) -> pure (TransientFailure "inbox row is still in progress")
  Right (Right (InboxPreviouslyFailed _)) -> pure (permanentInboxFailure event)
  Right (Right (InboxHandlerFailed _ _)) -> pure (permanentInboxFailure event)
  Right (Left inboxError) -> pure (TransientFailure (Text.pack (show inboxError)))
  Left storeError -> pure (TransientFailure (Text.pack (show storeError)))

permanentInboxFailure :: IntegrationEvent -> RecordDisposition
permanentInboxFailure event =
  PermanentlyDeadLettered (DeadLetterId ("keiro-inbox:" <> event ^. #messageId))

persistPoison :: AppEnv -> QueueName -> KafkaInboundRecord -> Text -> IO RecordDisposition
persistPoison appEnv queue KafkaInboundRecord {topic, partition, offset, payload} failure = do
  recordedAt <- getCurrentTime
  let byteCount = ByteString.length payload
      evidence =
        PayloadEvidence
          { byteCount,
            sample = ByteString.unpack (ByteString.take evidenceLimit payload),
            truncated = byteCount > evidenceLimit
          }
      deadLetter =
        DeadLetterRecord
          { topic,
            partition,
            offset,
            error = Text.take errorLimit failure,
            evidence,
            recordedAt
          }
      send =
        Tx.statement
          SendMessage
            { queueName = queue,
              messageBody = MessageBody (Aeson.toJSON deadLetter),
              delay = Nothing
            }
          PgmqStatements.sendMessage
  attempt <- Exception.try @NotifierStartError (runAppIO appEnv (runTransaction send))
  pure $ case attempt of
    Left storeStartupError -> TransientFailure (Text.pack (show storeStartupError))
    Right (Left storeError) -> TransientFailure (Text.pack (show storeError))
    Right (Right (MessageId messageId)) -> PermanentlyDeadLettered (DeadLetterId (Text.pack (show messageId)))

evidenceLimit :: Int
evidenceLimit = 256

errorLimit :: Int
errorLimit = 2_048

-- | The only translation from application durability to broker mechanics.
ackDecisionFor :: RecordDisposition -> AckDecision
ackDecisionFor = \case
  Enqueued -> AckOk
  Duplicate -> AckOk
  PermanentlyDeadLettered (DeadLetterId deadLetterId) ->
    AckDeadLetter (ApplicationFailure permanentFailureCode ("durable dead letter " <> deadLetterId))
  TransientFailure err -> AckHalt (HaltOrderedStream (Text.take errorLimit err))

permanentFailureCode :: DeadLetterCode
permanentFailureCode =
  case mkDeadLetterCode "shikigami.consumer_permanent" of
    Left err -> Prelude.error (Text.unpack err)
    Right code -> code

-- | Reconcile the operator-owned poison queue at startup.
ensureDeadLetterQueue :: Pool -> QueueName -> IO (Either UsageError ())
ensureDeadLetterQueue pool queue = Pool.use pool (createQueue queue)

logDisposition :: Log.Logger -> Text -> RecordDisposition -> IO ()
logDisposition logger prefix = \case
  Enqueued -> Log.logDebug logger (prefix <> ".record.enqueued") []
  Duplicate -> Log.logDebug logger (prefix <> ".record.deduped") []
  PermanentlyDeadLettered (DeadLetterId deadLetterId) ->
    Log.logError logger (prefix <> ".record.dead_lettered") ["dead_letter_id" Aeson..= deadLetterId]
  TransientFailure err -> Log.logError logger (prefix <> ".record.transient_failure") ["error" Aeson..= err]

data PreparedTrigger hit
  = EnqueueTrigger !RunJob !hit
  | SkipTrigger !RunSkip

data CommittedTrigger hit
  = EnqueuedTrigger !hit
  | SkippedTrigger !RunSkip

prepareActivityHits :: Directory.DirectoryHandle -> UTCTime -> IncludeAgentActors -> [AgentDecl] -> ActivityEnvelope -> IO [PreparedTrigger StreamHit]
prepareActivityHits directory resolvedOccurredAt include agents activity =
  traverse
    prepare
    [ agent
    | agent <- agents,
      Just streamMatch <- [streamMatchOf agent],
      matchesStreamWith include streamMatch activity
    ]
  where
    prepare agent = do
      let job = runJobFromEnvelopeWithIdentity resolvedOccurredAt UnresolvedLegacyIdentity agent activity
          hit = StreamHit {agentName = agent ^. #name, envelope = activity}
      prepareTrigger directory "stream" agent job hit

-- | Queue sends and lifecycle refusals share the inbox transaction. A broker
-- offset is acknowledged only after exactly one durable effect commits.
inboxHandler :: [PreparedTrigger StreamHit] -> IntegrationEvent -> Tx.Transaction [CommittedTrigger StreamHit]
inboxHandler prepared _event = traverse commitTrigger prepared

streamMatchOf :: AgentDecl -> Maybe StreamMatch
streamMatchOf agent = case agent ^. #trigger of
  Stream {match = streamMatch} -> Just streamMatch
  _ -> Nothing

prepareEventHits :: Directory.DirectoryHandle -> UTCTime -> [AgentDecl] -> Value -> IntegrationEvent -> IO [PreparedTrigger EventHit]
prepareEventHits directory receivedAt agents payloadValue event =
  traverse
    prepare
    [ agent
    | agent <- agents,
      Just expectedEventType <- [eventTriggerTypeOf agent],
      expectedEventType == event ^. #eventType
    ]
  where
    prepare agent = do
      let job =
            RunJob
              { agentName = AgentName (agent ^. #name),
                identity = UnresolvedLegacyIdentity,
                triggerKind = TriggeredByEvent,
                routeKind = eventRouteOf agent,
                occurredAt = receivedAt,
                triggerPayload = payloadValue,
                idempotencyKey = RunKey (agent ^. #name <> ":" <> event ^. #messageId),
                parentSessionId = Nothing,
                parentRunWorkflowId = Nothing,
                delegationDepth = Nothing,
                lineage = [AgentName (agent ^. #name)],
                executionRequest = Nothing,
                executionPermissions = Nothing,
                executionRootId = Nothing,
                delegationBudgetId = Nothing
              }
          hit =
            EventHit
              { agentName = agent ^. #name,
                eventType = event ^. #eventType,
                integrationMessageId = event ^. #messageId,
                payload = payloadValue
              }
      prepareTrigger directory "event" agent job hit

eventInboxHandler :: [PreparedTrigger EventHit] -> IntegrationEvent -> Tx.Transaction [CommittedTrigger EventHit]
eventInboxHandler prepared _event = traverse commitTrigger prepared

prepareTrigger :: Directory.DirectoryHandle -> Text -> AgentDecl -> RunJob -> hit -> IO (PreparedTrigger hit)
prepareTrigger directory detail agent job hit = do
  let declaredPrincipalId = principalIdOf agent
  decision <- Directory.consultLifecycle directory declaredPrincipalId (agent ^. #name)
  pure case decision of
    Directory.AllowRun Nothing -> EnqueueTrigger (job {RunJob.identity = compatibilityIdentity (agent ^. #name)}) hit
    Directory.AllowRun (Just principal) ->
      case mkAgentPrincipal ((.principalId) principal) of
        Right admittedPrincipal -> EnqueueTrigger (job {RunJob.identity = VerifiedIdentity admittedPrincipal}) hit
        Left reason -> refused (Just ((.principalId) principal)) reason
    Directory.SkipRun principal reason -> refused (Just ((.principalId) principal)) reason
    Directory.UnknownPrincipal identifier -> refused declaredPrincipalId ("unknown principal: " <> identifier)
    Directory.DirectoryUnavailable problem -> refused declaredPrincipalId ("directory unavailable: " <> problem)
  where
    refused resolvedPrincipalId reason =
      SkipTrigger
        RunSkip
          { agentName = agent ^. #name,
            principalId = resolvedPrincipalId,
            stage = TriggerStage,
            detail,
            reason,
            idempotencyKey = runKeyText (job ^. #idempotencyKey)
          }

commitTrigger :: PreparedTrigger hit -> Tx.Transaction (CommittedTrigger hit)
commitTrigger = \case
  EnqueueTrigger job hit -> do
    _ <- enqueueRunJobTx job
    pure (EnqueuedTrigger hit)
  SkipTrigger runSkip -> do
    recordRunSkipTx runSkip
    pure (SkippedTrigger runSkip)

reportCommitted :: Log.Logger -> Text -> (hit -> IO ()) -> CommittedTrigger hit -> IO ()
reportCommitted logger prefix onHit = \case
  EnqueuedTrigger hit -> onHit hit
  SkippedTrigger RunSkip {agentName, principalId, detail, reason, idempotencyKey} ->
    Log.logInfo
      logger
      (prefix <> ".trigger.skipped")
      [ "agent" Aeson..= agentName,
        "principal_id" Aeson..= principalId,
        "detail" Aeson..= detail,
        "reason" Aeson..= reason,
        Log.runIdKey Aeson..= idempotencyKey
      ]

principalIdOf :: AgentDecl -> Maybe Text
principalIdOf AgentDecl {identity} = declared <$> identity
  where
    declared IdentityDecl {principal} = principal

eventTriggerTypeOf :: AgentDecl -> Maybe Text
eventTriggerTypeOf agent = case agent ^. #trigger of
  Event {eventType} -> Just eventType
  _ -> Nothing

-- | The declared event type is the honest source of the conversation/agent-run
-- distinction: an agent that subscribes to @danwa.message-addressed-to-agent@ is
-- asking for a conversation turn, and every other event trigger is an ordinary
-- agent run. Deciding here, where the declaration is in scope, is what lets the
-- worker stop guessing from the payload's shape.
eventRouteOf :: AgentDecl -> RunRouteKind
eventRouteOf agent
  | eventTriggerTypeOf agent == Just Danwa.addressedMessageEventType = ConversationWorkflowRoute
  | otherwise = AgentWorkflowRoute
