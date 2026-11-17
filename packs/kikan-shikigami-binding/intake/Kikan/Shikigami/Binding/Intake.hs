{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

-- | The Kafka transport of the Kawa stream and integration-event intake
-- (plan 135, M5). Shibuya owns polling and offset storage. Each delivered
-- record is handed to the kernel's record intake ("Shikigami.Trigger.Intake"),
-- which establishes exactly one durable disposition; this module turns that
-- disposition into the one ack decision the broker sees.
--
-- It lives in the binding's @intake@ library, apart from the binding itself,
-- so that only the distribution's consumer executables link a Kafka client.
module Kikan.Shikigami.Binding.Intake
  ( OnSupervisor,
    StreamConfig (..),
    subscribeActivityStream,
    subscribeIntegrationEventStream,
    kafkaReconnectAllowed,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception qualified as Exception
import Data.Aeson ((.=))
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Text.Read qualified as TextRead
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Exception qualified as EffException
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
import Keiro.Inbox.Kafka (KafkaInboundRecord (..))
import Pgmq (QueueName)
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.App qualified as Shibuya
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..))
import Shibuya.Policy (Concurrency (Serial), OrderingPolicy (StrictInOrder))
import Shibuya.Telemetry.Effect (runTracing)
import Shikigami.Agent.Conversation.Channel (ConversationChannels)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.App (AppEnv (..))
import Shikigami.Directory qualified as Directory
import Shikigami.Inspection.Consumer (ConsumerInspection, withConsumerInspection)
import Shikigami.Integration.ConsumerRuntime (consumerAppConfig, withConsumerApp)
import Shikigami.Log qualified as Log
import Shikigami.Prelude hiding ((.=))
import Shikigami.Telemetry.Metrics (ShikigamiMetrics, recordConsumerRecord, recordStreamDisposition)
import Shikigami.Trigger.Hook (StreamIntake)
import Shikigami.Trigger.Intake
  ( EventHit,
    RecordDisposition (..),
    StreamHit,
    ackDecisionFor,
    dispositionErrorLimit,
    logDisposition,
    permanentFailureCode,
    processActivityRecordWithDirectory,
    processIntegrationEventRecordWithDirectory,
  )
import Shikigami.Trigger.Stream (IncludeAgentActors)

-- | Connection and durable poison-record target for one Kafka subscription.
data StreamConfig = StreamConfig
  { broker :: !Text,
    topic :: !Text,
    consumerGroupId :: !Text,
    deadLetterQueue :: !QueueName,
    inspection :: !ConsumerInspection
  }

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
subscribeActivityStream :: Log.Logger -> OnSupervisor -> ShikigamiMetrics -> AppEnv -> Directory.DirectoryHandle -> StreamIntake -> StreamConfig -> IncludeAgentActors -> [AgentDecl] -> (StreamHit -> IO ()) -> IO ()
subscribeActivityStream logger onSupervisor metrics appEnv directory intake config@StreamConfig {deadLetterQueue} include agents onHit =
  runSubscription logger onSupervisor "stream" metrics appEnv config $ processActivityRecordWithDirectory logger appEnv directory intake (recordStreamDisposition metrics) deadLetterQueue include agents onHit

-- | Subscribe to a public integration-event topic through the same durable
-- acknowledgement boundary. An agent whose event type a composed conversation
-- channel serves takes a conversation turn.
subscribeIntegrationEventStream :: Log.Logger -> OnSupervisor -> ShikigamiMetrics -> AppEnv -> Directory.DirectoryHandle -> ConversationChannels -> StreamConfig -> [AgentDecl] -> (EventHit -> IO ()) -> IO ()
subscribeIntegrationEventStream logger onSupervisor metrics appEnv directory channels config@StreamConfig {deadLetterQueue} agents onHit =
  runSubscription logger onSupervisor "events" metrics appEnv config $ processIntegrationEventRecordWithDirectory logger appEnv directory channels deadLetterQueue agents onHit

runSubscription ::
  Log.Logger ->
  OnSupervisor ->
  Text ->
  ShikigamiMetrics ->
  AppEnv ->
  StreamConfig ->
  (KafkaInboundRecord -> IO RecordDisposition) ->
  IO ()
runSubscription logger onSupervisor prefix metrics AppEnv {tracer} StreamConfig {broker = streamBroker, topic = streamTopic, consumerGroupId = streamGroup, inspection} processRecord =
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
                      pure (AckHalt (HaltFatal (Text.take dispositionErrorLimit (Text.pack (show err)))))
                    Right disposition -> pure (ackDecisionFor disposition)
                processor =
                  Shibuya.QueueProcessor
                    { adapter,
                      handler,
                      ordering = StrictInOrder,
                      concurrency = Serial
                    }
            appResult <-
              ( withConsumerApp consumerAppConfig [(Shibuya.ProcessorId streamTopic, processor)] \app -> withConsumerInspection inspection (Shibuya.getAppMaster app) do
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
        [ "delay_seconds" .= seconds,
          "reason" .= reason
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
