{-# LANGUAGE TypeApplications #-}

-- | The live @activity.v1@ stream trigger (C3, class 2). A consumer that decodes each
-- Kafka record through the keiro idempotent inbox (C9), runs 'matchesStream' for each
-- declared stream agent, and reports the hits. Offsets are committed manually only
-- after the inbox transaction commits (Open Question 7), so a restart neither
-- double-fires (inbox dedup guards) nor loses position.
module Shikigami.Trigger.Consumer
  ( StreamConfig (..),
    StreamHit (..),
    subscribeActivityStream,
  )
where

import Data.ByteString (ByteString)
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
import Shikigami.Api.Activity (ActivityEnvelope)
import Shikigami.Api.Agent (AgentDecl (..), StreamMatch, Trigger (..))
import Shikigami.Prelude
import Shikigami.Trigger.Stream (IncludeAgentActors, matchesStreamWith)
import System.IO (hPutStrLn, stderr)

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

-- | Subscribe to the activity stream and report each declared stream agent that
-- matches an incoming envelope. Decodes via the keiro inbox; a re-delivery is logged
-- and not re-fired. Runs forever.
subscribeActivityStream :: AppEnv -> StreamConfig -> IncludeAgentActors -> [AgentDecl] -> (StreamHit -> IO ()) -> IO ()
subscribeActivityStream appEnv StreamConfig {broker = streamBroker, topic = streamTopic, consumerGroupId = streamGroup} include agents onHit = do
  let props =
        brokersList [BrokerAddress streamBroker]
          <> groupId (ConsumerGroupId streamGroup)
          <> noAutoCommit
      sub = topics [TopicName streamTopic] <> offsetReset Earliest
  result <- runEff . runError @KafkaError $ runKafkaConsumer props sub loop
  case result of
    Left err -> hPutStrLn stderr ("[stream] consumer error: " <> show err)
    Right () -> pure ()
  where
    loop :: (KafkaConsumer :> es, IOE :> es) => Eff es ()
    loop = do
      mr <- pollMessage (Timeout 1000)
      case mr of
        Nothing -> loop
        Just record -> do
          liftIO (processRecord appEnv include agents onHit record)
          commitOffsetMessage OffsetCommit record
          loop

-- | Decode one record through the keiro inbox and fire the matching agents.
processRecord ::
  AppEnv ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
  IO ()
processRecord appEnv include agents onHit record = do
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
    Left err -> hPutStrLn stderr ("[stream] decode error (skipped + committed): " <> show err)
    Right (event, kref) -> do
      res <-
        runAppIO appEnv $
          runInboxTransaction Nothing PreferIntegrationMessageId event (Just kref) (inboxHandler include agents)
      case res of
        Right (Right (InboxProcessed hits)) -> mapM_ onHit hits
        Right (Right InboxDuplicate) -> hPutStrLn stderr "[stream] deduped (InboxDuplicate)"
        Right (Right other) -> hPutStrLn stderr ("[stream] inbox result: " <> show other)
        Right (Left ierr) -> hPutStrLn stderr ("[stream] inbox error: " <> show ierr)
        Left serr -> hPutStrLn stderr ("[stream] store error: " <> show serr)

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
