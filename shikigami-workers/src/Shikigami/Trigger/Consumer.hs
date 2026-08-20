{-# LANGUAGE TypeApplications #-}

-- | Durable Kafka consumers for stream and public integration-event triggers.
-- Shibuya owns polling and offset storage; application code establishes one of
-- the explicit durable dispositions below and returns exactly one ack decision.
module Shikigami.Trigger.Consumer
  ( StreamConfig (..),
    StreamHit (..),
    EventHit (..),
    DeadLetterId (..),
    PayloadEvidence (..),
    DeadLetterRecord (..),
    RecordDisposition (..),
    subscribeActivityStream,
    subscribeIntegrationEventStream,
    processActivityRecord,
    processIntegrationEventRecord,
    processDecodedActivity,
    processDecodedIntegrationEvent,
    ackDecisionFor,
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
import Effectful.Error.Static (runError)
import Hasql.Pool (Pool, UsageError)
import Hasql.Pool qualified as Pool
import Hasql.Transaction qualified as Tx
import Kafka.Consumer
  ( ConsumerGroupId (..),
    OffsetReset (..),
    TopicName (..),
    brokersList,
    groupId,
    noAutoOffsetStore,
    offsetReset,
    topics,
  )
import Kafka.Effectful (KafkaError, runKafkaConsumer)
import Kafka.Types (BrokerAddress (..))
import Keiro.Inbox (runInboxTransaction)
import Keiro.Inbox.Kafka (KafkaInboundRecord (..), integrationEventFromKafka)
import Keiro.Inbox.Types (InboxDedupePolicy (PreferIntegrationMessageId), InboxResult (..), KafkaDeliveryRef (..))
import Keiro.Integration.Event (IntegrationEvent, decodeJsonIntegrationEvent)
import Kioku.App (AppEnv (..), runAppIO)
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
import Shikigami.Agent.Decl (AgentDecl (..), StreamMatch, Trigger (..))
import Shikigami.Agent.RunJob (RunJob (..), TriggerKind (TriggeredByEvent))
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Trigger.Enqueue (enqueueRunJobTx, runJobFromEnvelope)
import Shikigami.Trigger.Stream (IncludeAgentActors, matchesStreamWith)

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

-- | Subscribe to @activity.v1@ through the serial Shibuya Kafka adapter.
subscribeActivityStream :: Log.Logger -> AppEnv -> StreamConfig -> IncludeAgentActors -> [AgentDecl] -> (StreamHit -> IO ()) -> IO ()
subscribeActivityStream logger appEnv config@StreamConfig {deadLetterQueue} include agents onHit =
  runSubscription logger "stream" appEnv config $ processActivityRecord appEnv deadLetterQueue include agents onHit

-- | Subscribe to a public integration-event topic through the same durable
-- acknowledgement boundary.
subscribeIntegrationEventStream :: Log.Logger -> AppEnv -> StreamConfig -> [AgentDecl] -> (EventHit -> IO ()) -> IO ()
subscribeIntegrationEventStream logger appEnv config@StreamConfig {deadLetterQueue} agents onHit =
  runSubscription logger "events" appEnv config $ processIntegrationEventRecord appEnv deadLetterQueue agents onHit

runSubscription ::
  Log.Logger ->
  Text ->
  AppEnv ->
  StreamConfig ->
  (KafkaInboundRecord -> IO RecordDisposition) ->
  IO ()
runSubscription logger prefix AppEnv {tracer} StreamConfig {broker = streamBroker, topic = streamTopic, consumerGroupId = streamGroup} processRecord =
  reconnect 1
  where
    reconnect backoffSeconds = do
      let props =
            brokersList [BrokerAddress streamBroker]
              <> groupId (ConsumerGroupId streamGroup)
              <> noAutoOffsetStore
          sub = topics [TopicName streamTopic] <> offsetReset Earliest
      result <-
        runEff . runError @KafkaError . runTracing tracer $
          runKafkaConsumer props sub do
            adapter <- kafkaAdapter (defaultConfig [TopicName streamTopic])
            programmingFailure <- liftIO (newIORef Nothing)
            let handler message = do
                  attempt <-
                    liftIO . trySynchronous $ do
                      disposition <- processKafkaMessage streamTopic processRecord message
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
                appConfig =
                  Shibuya.AppConfig
                    { strategy = Shibuya.StopAllOnFailure,
                      inboxSize = 1
                    }
            appResult <- Shibuya.runApp appConfig [(Shibuya.ProcessorId streamTopic, processor)]
            case appResult of
              Left err -> pure (Left err)
              Right app -> do
                Shibuya.waitApp app
                Shibuya.stopApp app
                failure <- liftIO (readIORef programmingFailure)
                pure (Right failure)
      case result of
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

trySynchronous :: IO value -> IO (Either Exception.SomeException value)
trySynchronous action =
  Exception.try action >>= \case
    Left err
      | Just (_ :: Exception.SomeAsyncException) <- Exception.fromException err -> Exception.throwIO err
      | otherwise -> pure (Left err)
    Right value -> pure (Right value)

processKafkaMessage :: Text -> (KafkaInboundRecord -> IO RecordDisposition) -> Message es (Maybe ByteString) -> IO RecordDisposition
processKafkaMessage streamTopic processRecord Message {envelope = Envelope {cursor, partition, headers, payload}} = do
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
    Right record -> processRecord record

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
  AppEnv ->
  QueueName ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  KafkaInboundRecord ->
  IO RecordDisposition
processActivityRecord appEnv queue include agents onHit record =
  case integrationEventFromKafka record of
    Left err -> persistPoison appEnv queue record (Text.pack (show err))
    Right (event, delivery) ->
      case decodeJsonIntegrationEvent event of
        Left err -> persistPoison appEnv queue record (Text.pack (show err))
        Right activity -> processActivity appEnv include agents onHit event (Just delivery) activity

-- | Process one raw public integration-event delivery.
processIntegrationEventRecord ::
  AppEnv ->
  QueueName ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  KafkaInboundRecord ->
  IO RecordDisposition
processIntegrationEventRecord appEnv queue agents onHit record =
  case integrationEventFromKafka record of
    Left err -> persistPoison appEnv queue record (Text.pack (show err))
    Right (event, delivery) ->
      case decodeJsonIntegrationEvent event of
        Left err -> persistPoison appEnv queue record (Text.pack (show err))
        Right payloadValue -> processIntegrationEvent appEnv agents onHit event (Just delivery) payloadValue

-- | Process an already decoded transport event. An invalid activity payload is
-- transient here because this broker-free entry point has no raw delivery to
-- preserve; the raw-record entry point above durably dead-letters it.
processDecodedActivity ::
  AppEnv ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  IO RecordDisposition
processDecodedActivity appEnv include agents onHit event kafka =
  case decodeJsonIntegrationEvent event of
    Left err -> pure (TransientFailure (Text.pack (show err)))
    Right activity -> processActivity appEnv include agents onHit event kafka activity

processActivity ::
  AppEnv ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  ActivityEnvelope ->
  IO RecordDisposition
processActivity appEnv include agents onHit event kafka activity = do
  attempt <-
    Exception.try @NotifierStartError $
      runAppIO appEnv $
        runInboxTransaction Nothing PreferIntegrationMessageId event kafka (inboxHandler include agents activity)
  case attempt of
    Left storeStartupError -> pure (TransientFailure (Text.pack (show storeStartupError)))
    Right result -> classifyInboxResult event onHit result

-- | Broker-free transactional entry point for public integration events.
processDecodedIntegrationEvent ::
  AppEnv ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  IO RecordDisposition
processDecodedIntegrationEvent appEnv agents onHit event kafka =
  case decodeJsonIntegrationEvent event of
    Left err -> pure (TransientFailure (Text.pack (show err)))
    Right payloadValue -> processIntegrationEvent appEnv agents onHit event kafka payloadValue

processIntegrationEvent ::
  AppEnv ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  Value ->
  IO RecordDisposition
processIntegrationEvent appEnv agents onHit event kafka payloadValue = do
  receivedAt <- getCurrentTime
  attempt <-
    Exception.try @NotifierStartError $
      runAppIO appEnv $
        runInboxTransaction Nothing PreferIntegrationMessageId event kafka (eventInboxHandler receivedAt agents payloadValue)
  case attempt of
    Left storeStartupError -> pure (TransientFailure (Text.pack (show storeStartupError)))
    Right result -> classifyInboxResult event onHit result

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

-- | Matching and queue sends run inside the inbox transaction.
inboxHandler :: IncludeAgentActors -> [AgentDecl] -> ActivityEnvelope -> IntegrationEvent -> Tx.Transaction [StreamHit]
inboxHandler include agents activity _event = do
  let matched =
        [ agent
        | agent <- agents,
          Just streamMatch <- [streamMatchOf agent],
          matchesStreamWith include streamMatch activity
        ]
  traverse_ (enqueueRunJobTx . (`runJobFromEnvelope` activity)) matched
  pure [StreamHit {agentName = agent ^. #name, envelope = activity} | agent <- matched]

streamMatchOf :: AgentDecl -> Maybe StreamMatch
streamMatchOf agent = case agent ^. #trigger of
  Stream {match = streamMatch} -> Just streamMatch
  _ -> Nothing

eventInboxHandler :: UTCTime -> [AgentDecl] -> Value -> IntegrationEvent -> Tx.Transaction [EventHit]
eventInboxHandler receivedAt agents payloadValue event = do
  let matched =
        [ agent
        | agent <- agents,
          Just expectedEventType <- [eventTriggerTypeOf agent],
          expectedEventType == event ^. #eventType
        ]
      jobFor agent =
        RunJob
          { agentName = agent ^. #name,
            triggerKind = TriggeredByEvent,
            occurredAt = receivedAt,
            triggerPayload = payloadValue,
            idempotencyKey = agent ^. #name <> ":" <> event ^. #messageId,
            parentSessionId = Nothing,
            parentRunWorkflowId = Nothing,
            delegationDepth = Nothing
          }
  traverse_ (enqueueRunJobTx . jobFor) matched
  pure
    [ EventHit
        { agentName = agent ^. #name,
          eventType = event ^. #eventType,
          integrationMessageId = event ^. #messageId,
          payload = payloadValue
        }
    | agent <- matched
    ]

eventTriggerTypeOf :: AgentDecl -> Maybe Text
eventTriggerTypeOf agent = case agent ^. #trigger of
  Event {eventType} -> Just eventType
  _ -> Nothing
