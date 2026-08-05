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
    subscribeActivityStream,
    subscribeIntegrationEventStream,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
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
import Keiro.Inbox.Types (InboxDedupePolicy (PreferIntegrationMessageId), InboxResult (..))
import Keiro.Integration.Event (IntegrationEvent, decodeJsonIntegrationEvent)
import Kioku.App (AppEnv, runAppIO)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Decl (AgentDecl (..), StreamMatch, Trigger (..))
import Shikigami.Log qualified as Log
import Shikigami.Prelude
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
  { streamAgentName :: !Text,
    envelope :: !ActivityEnvelope
  }
  deriving stock (Eq, Show)

-- | A matched event-triggered agent and the public integration-event payload.
data EventHit = EventHit
  { eventAgentName :: !Text,
    eventType :: !Text,
    integrationMessageId :: !Text,
    payload :: !Value
  }
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
      res <-
        runAppIO appEnv $
          runInboxTransaction Nothing PreferIntegrationMessageId event (Just kref) (inboxHandler include agents)
      case res of
        Right (Right (InboxProcessed hits)) -> mapM_ onHit hits
        Right (Right InboxDuplicate) -> recordLog Log.Debug "stream.record.deduped" []
        Right (Right other) -> recordLog Log.Info "stream.inbox.other" ["result" Aeson..= Text.pack (show other)]
        Right (Left ierr) -> recordLog Log.Error "stream.inbox.failed" ["error" Aeson..= Text.pack (show ierr)]
        Left serr -> recordLog Log.Error "stream.store.failed" ["error" Aeson..= Text.pack (show serr)]
  where
    -- Every line about one record names the topic and offset it came from, so a
    -- report of a skipped record says which record was skipped.
    recordLog level event fields =
      Log.logEvent logger level event (recordFields record <> fields)

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
      res <-
        runAppIO appEnv $
          runInboxTransaction Nothing PreferIntegrationMessageId event (Just kref) (eventInboxHandler agents)
      case res of
        Right (Right (InboxProcessed hits)) -> mapM_ onHit hits
        Right (Right InboxDuplicate) -> recordLog Log.Debug "events.record.deduped" []
        Right (Right other) -> recordLog Log.Info "events.inbox.other" ["result" Aeson..= Text.pack (show other)]
        Right (Left ierr) -> recordLog Log.Error "events.inbox.failed" ["error" Aeson..= Text.pack (show ierr)]
        Left serr -> recordLog Log.Error "events.store.failed" ["error" Aeson..= Text.pack (show serr)]
  where
    recordLog level event fields =
      Log.logEvent logger level event (recordFields record <> fields)

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

-- | The inbox handler (runs in the inbox DB transaction): decode the envelope and
-- collect the matching stream agents. Pure work wrapped in @pure@.
inboxHandler :: IncludeAgentActors -> [AgentDecl] -> IntegrationEvent -> Tx.Transaction [StreamHit]
inboxHandler include agents event =
  case decodeJsonIntegrationEvent event of
    Left _ -> pure []
    Right env ->
      pure
        [ StreamHit (name a) env
        | a <- agents,
          Just m <- [streamMatchOf a],
          matchesStreamWith include m env
        ]

-- | The 'StreamMatch' of an agent, if its trigger is a stream trigger.
streamMatchOf :: AgentDecl -> Maybe StreamMatch
streamMatchOf a = case trigger a of
  Stream {match = m} -> Just m
  _ -> Nothing

eventInboxHandler :: [AgentDecl] -> IntegrationEvent -> Tx.Transaction [EventHit]
eventInboxHandler agents event =
  case decodeJsonIntegrationEvent event of
    Left _ -> pure []
    Right payloadValue ->
      pure
        [ EventHit
            { eventAgentName = name a,
              eventType = event ^. #eventType,
              integrationMessageId = event ^. #messageId,
              payload = payloadValue
            }
        | a <- agents,
          Just expectedEventType <- [eventTriggerTypeOf a],
          expectedEventType == event ^. #eventType
        ]

eventTriggerTypeOf :: AgentDecl -> Maybe Text
eventTriggerTypeOf a = case trigger a of
  Event {eventType = t} -> Just t
  _ -> Nothing
