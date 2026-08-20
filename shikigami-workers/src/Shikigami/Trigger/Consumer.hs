{-# LANGUAGE TypeApplications #-}

-- | The live @activity.v1@ stream trigger (C3, class 2). A consumer that decodes each
-- Kafka record through the keiro idempotent inbox (C9), runs 'matchesStream' for each
-- declared stream agent, and reports the hits. Offsets are committed manually only
-- after the inbox transaction commits (Open Question 7), so a restart neither
-- double-fires (inbox dedup guards) nor loses position.
module Shikigami.Trigger.Consumer
  ( StreamConfig (..),
    StreamHit (..),
    EventHit (..),
    DeadLetterId (..),
    RecordDisposition (..),
    subscribeActivityStream,
    subscribeIntegrationEventStream,
    processDecodedActivity,
    processDecodedIntegrationEvent,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (runError)
import Hasql.Transaction qualified as Tx
import Kafka.Consumer
  ( ConsumerGroupId (..),
    ConsumerRecord (..),
    Offset (..),
    OffsetReset (..),
    PartitionId (..),
    Timeout (..),
    TopicName (..),
    brokersList,
    groupId,
    noAutoCommit,
    offsetReset,
    topics,
  )
import Kafka.Effectful (KafkaConsumer, KafkaError, OffsetCommit (OffsetCommit), commitOffsetMessage, pollMessage, runKafkaConsumer)
import Kafka.Types (BrokerAddress (..), headersToList)
import Keiro.Inbox (runInboxTransaction)
import Keiro.Inbox.Kafka (KafkaInboundRecord (..), integrationEventFromKafka)
import Keiro.Inbox.Types (InboxDedupePolicy (PreferIntegrationMessageId), InboxResult (..), KafkaDeliveryRef)
import Keiro.Integration.Event (IntegrationEvent, decodeJsonIntegrationEvent)
import Kioku.App (AppEnv, runAppIO)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Decl (AgentDecl (..), StreamMatch, Trigger (..))
import Shikigami.Agent.RunJob (RunJob (..), TriggerKind (TriggeredByEvent))
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Trigger.Enqueue (enqueueRunJobTx, runJobFromEnvelope)
import Shikigami.Trigger.Stream (IncludeAgentActors, matchesStreamWith)

-- | Where to consume the activity stream.
data StreamConfig = StreamConfig
  { broker :: !Text, -- "host:port"
    topic :: !Text, -- "activity.v1"
    consumerGroupId :: !Text
  }
  deriving stock (Eq, Show)

-- | A matched (agent, envelope) pair the consumer reports.
data StreamHit = StreamHit
  { agentName :: !Text,
    envelope :: !ActivityEnvelope
  }
  deriving stock (Eq, Show)

-- | A matched event-triggered agent and the public integration-event payload.
data EventHit = EventHit
  { agentName :: !Text,
    eventType :: !Text,
    integrationMessageId :: !Text,
    payload :: !Value
  }
  deriving stock (Eq, Show)

-- | Durable identity returned by poison-record storage.
newtype DeadLetterId = DeadLetterId Text
  deriving stock (Eq, Show)

-- | What durable processing established for one Kafka delivery.
data RecordDisposition
  = Enqueued
  | Duplicate
  | PermanentlyDeadLettered !DeadLetterId
  | TransientFailure !Text
  deriving stock (Eq, Show)

-- | Subscribe to the activity stream and report each declared stream agent that
-- matches an incoming envelope. Decodes via the keiro inbox; a re-delivery is logged
-- and not re-fired. Runs forever.
subscribeActivityStream :: Log.Logger -> AppEnv -> StreamConfig -> IncludeAgentActors -> [AgentDecl] -> (StreamHit -> IO ()) -> IO ()
subscribeActivityStream logger appEnv StreamConfig {broker = streamBroker, topic = streamTopic, consumerGroupId = streamGroup} include agents onHit = do
  let props =
        brokersList [BrokerAddress streamBroker]
          <> groupId (ConsumerGroupId streamGroup)
          <> noAutoCommit
      sub = topics [TopicName streamTopic] <> offsetReset Earliest
  result <- runEff . runError @KafkaError $ runKafkaConsumer props sub loop
  case result of
    Left err -> Log.logError logger "stream.consumer.failed" ["topic" Aeson..= streamTopic, "error" Aeson..= Text.pack (show err)]
    Right () -> pure ()
  where
    loop :: (KafkaConsumer :> es, IOE :> es) => Eff es ()
    loop = do
      mr <- pollMessage (Timeout 1000)
      case mr of
        Nothing -> loop
        Just record -> do
          liftIO (processRecord logger appEnv include agents onHit record)
          commitOffsetMessage OffsetCommit record
          loop

-- | Subscribe to a public integration-event topic and report declared event
-- agents whose `Trigger.Event.eventType` matches the integration event type.
--
-- This is the supported path for Danwa addressed-message events. It consumes
-- the public topic Danwa publishes; it does not read Danwa's database.
subscribeIntegrationEventStream :: Log.Logger -> AppEnv -> StreamConfig -> [AgentDecl] -> (EventHit -> IO ()) -> IO ()
subscribeIntegrationEventStream logger appEnv StreamConfig {broker = streamBroker, topic = streamTopic, consumerGroupId = streamGroup} agents onHit = do
  let props =
        brokersList [BrokerAddress streamBroker]
          <> groupId (ConsumerGroupId streamGroup)
          <> noAutoCommit
      sub = topics [TopicName streamTopic] <> offsetReset Earliest
  result <- runEff . runError @KafkaError $ runKafkaConsumer props sub loop
  case result of
    Left err -> Log.logError logger "events.consumer.failed" ["topic" Aeson..= streamTopic, "error" Aeson..= Text.pack (show err)]
    Right () -> pure ()
  where
    loop :: (KafkaConsumer :> es, IOE :> es) => Eff es ()
    loop = do
      mr <- pollMessage (Timeout 1000)
      case mr of
        Nothing -> loop
        Just record -> do
          liftIO (processEventRecord logger appEnv agents onHit record)
          commitOffsetMessage OffsetCommit record
          loop

-- | Decode one record through the keiro inbox and fire the matching agents.
processRecord ::
  Log.Logger ->
  AppEnv ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
  IO ()
processRecord logger appEnv include agents onHit record = do
  now <- getCurrentTime
  let TopicName topicT = crTopic record
      PartitionId partI = crPartition record
      Offset offI = crOffset record
      kir =
        KafkaInboundRecord
          { topic = topicT,
            partition = fromIntegral partI,
            offset = offI,
            key = TE.decodeUtf8 <$> crKey record,
            payload = fromMaybe mempty (crValue record),
            headers = [(TE.decodeUtf8 k, TE.decodeUtf8 v) | (k, v) <- headersToList (crHeaders record)],
            receivedAt = now
          }
  case integrationEventFromKafka kir of
    Left err -> recordLog Log.Error "stream.record.undecodable" ["error" Aeson..= Text.pack (show err)]
    Right (event, kref) -> do
      disposition <- processDecodedActivity appEnv include agents onHit event (Just kref)
      logDisposition "stream" disposition
  where
    -- Every line about one record names the topic and offset it came from, so a
    -- report of a skipped record says which record was skipped.
    recordLog level event fields =
      Log.logEvent logger level event (recordFields record <> fields)

    logDisposition prefix = \case
      Enqueued -> recordLog Log.Debug (prefix <> ".record.enqueued") []
      Duplicate -> recordLog Log.Debug (prefix <> ".record.deduped") []
      PermanentlyDeadLettered deadLetterId ->
        recordLog Log.Error (prefix <> ".record.dead_lettered") ["dead_letter_id" Aeson..= Text.pack (show deadLetterId)]
      TransientFailure err -> recordLog Log.Error (prefix <> ".record.transient_failure") ["error" Aeson..= err]

processEventRecord ::
  Log.Logger ->
  AppEnv ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
  IO ()
processEventRecord logger appEnv agents onHit record = do
  now <- getCurrentTime
  let TopicName topicT = crTopic record
      PartitionId partI = crPartition record
      Offset offI = crOffset record
      kir =
        KafkaInboundRecord
          { topic = topicT,
            partition = fromIntegral partI,
            offset = offI,
            key = TE.decodeUtf8 <$> crKey record,
            payload = fromMaybe mempty (crValue record),
            headers = [(TE.decodeUtf8 k, TE.decodeUtf8 v) | (k, v) <- headersToList (crHeaders record)],
            receivedAt = now
          }
  case integrationEventFromKafka kir of
    Left err -> recordLog Log.Error "events.record.undecodable" ["error" Aeson..= Text.pack (show err)]
    Right (event, kref) -> do
      disposition <- processDecodedIntegrationEvent appEnv agents onHit event (Just kref)
      logDisposition disposition
  where
    recordLog level event fields =
      Log.logEvent logger level event (recordFields record <> fields)

    logDisposition = \case
      Enqueued -> recordLog Log.Debug "events.record.enqueued" []
      Duplicate -> recordLog Log.Debug "events.record.deduped" []
      PermanentlyDeadLettered deadLetterId ->
        recordLog Log.Error "events.record.dead_lettered" ["dead_letter_id" Aeson..= Text.pack (show deadLetterId)]
      TransientFailure err -> recordLog Log.Error "events.record.transient_failure" ["error" Aeson..= err]

-- | Process a decoded activity event through the inbox transaction. Matching
-- run jobs are sent before that transaction commits; 'onHit' runs afterwards
-- and is therefore for reporting only.
processDecodedActivity ::
  AppEnv ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  IO RecordDisposition
processDecodedActivity appEnv include agents onHit event kafka = do
  result <-
    runAppIO appEnv $
      runInboxTransaction Nothing PreferIntegrationMessageId event kafka (inboxHandler include agents)
  classifyInboxResult onHit result

-- | Process a decoded public integration event through the same atomic inbox
-- plus run-job boundary used by the activity consumer.
processDecodedIntegrationEvent ::
  AppEnv ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  IO RecordDisposition
processDecodedIntegrationEvent appEnv agents onHit event kafka = do
  receivedAt <- getCurrentTime
  result <-
    runAppIO appEnv $
      runInboxTransaction Nothing PreferIntegrationMessageId event kafka (eventInboxHandler receivedAt agents)
  classifyInboxResult onHit result

classifyInboxResult ::
  (Show storeError, Show inboxError) =>
  (hit -> IO ()) ->
  Either storeError (Either inboxError (InboxResult [hit])) ->
  IO RecordDisposition
classifyInboxResult onHit = \case
  Right (Right (InboxProcessed hits)) -> traverse_ onHit hits >> pure Enqueued
  Right (Right InboxDuplicate) -> pure Duplicate
  Right (Right InboxInProgress) -> pure (TransientFailure "inbox row is still in progress")
  Right (Right (InboxPreviouslyFailed reason)) ->
    pure (TransientFailure ("inbox row previously failed: " <> fromMaybe "unknown failure" reason))
  Right (Right (InboxHandlerFailed reason attempts)) ->
    pure (TransientFailure ("inbox handler failed at attempt " <> Text.pack (show attempts) <> ": " <> reason))
  Right (Left inboxError) -> pure (TransientFailure (Text.pack (show inboxError)))
  Left storeError -> pure (TransientFailure (Text.pack (show storeError)))

-- | Which Kafka record a consumer line is about. Shared by both consumers so
-- that @topic@, @partition@, and @offset@ are spelled the same way in each.
recordFields :: ConsumerRecord (Maybe ByteString) (Maybe ByteString) -> [Pair]
recordFields record =
  let TopicName topicT = crTopic record
      PartitionId partI = crPartition record
      Offset offI = crOffset record
   in [ "topic" Aeson..= topicT,
        "partition" Aeson..= partI,
        "offset" Aeson..= offI
      ]

-- | The inbox handler runs matching and queue sends inside the inbox database
-- transaction. Returning from this handler does not make either write visible;
-- both become durable only when the surrounding transaction commits.
inboxHandler :: IncludeAgentActors -> [AgentDecl] -> IntegrationEvent -> Tx.Transaction [StreamHit]
inboxHandler include agents event =
  case decodeJsonIntegrationEvent event of
    Left _ -> pure []
    Right env -> do
      let matched =
            [ agent
            | agent <- agents,
              Just streamMatch <- [streamMatchOf agent],
              matchesStreamWith include streamMatch env
            ]
      traverse_ (enqueueRunJobTx . (`runJobFromEnvelope` env)) matched
      pure [StreamHit {agentName = agent ^. #name, envelope = env} | agent <- matched]

-- | The 'StreamMatch' of an agent, if its trigger is a stream trigger.
streamMatchOf :: AgentDecl -> Maybe StreamMatch
streamMatchOf agent = case agent ^. #trigger of
  Stream {match = m} -> Just m
  _ -> Nothing

eventInboxHandler :: UTCTime -> [AgentDecl] -> IntegrationEvent -> Tx.Transaction [EventHit]
eventInboxHandler receivedAt agents event =
  case decodeJsonIntegrationEvent event of
    Left _ -> pure []
    Right payloadValue -> do
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
  Event {eventType = t} -> Just t
  _ -> Nothing
