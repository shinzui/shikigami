{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

-- | Closing the living loop: re-publish an accepted kawa envelope onto the fixture
-- @activity.v1@ Kafka topic with the exact @keiro-*@ header set EP-4's consumer reads,
-- mirroring kawa's own producer. Invoked only when @stub-kawa --republish-topic@ is set.
module Shikigami.Sink.KawaStub.Republish
  ( mkRepublisher,
    republish,
  )
where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Text.Encoding qualified as TE
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Effectful (produceMessageSync, runKafkaProducer)
import Kafka.Producer
  ( BrokerAddress (..),
    ProducePartition (UnassignedPartition),
    ProducerRecord (..),
    TopicName (..),
    brokersList,
  )
import Kafka.Types (KafkaError, headersFromList)
import Shikigami.Activity (ActivityEnvelope (..), Subject (..))
import Shikigami.Activity.Coordinate (activityCoordinate, activityCoordinateText)
import Shikigami.Prelude
import Shikigami.Sink.Wire (IngestRequest (..))
import System.IO (hPutStrLn, stderr)

-- | Build the stub's republish hook for a broker + topic. Logs (does not throw) on
-- failure so a republish error never crashes the doorway response.
mkRepublisher :: Text -> Text -> (IngestRequest -> Text -> IO ())
mkRepublisher broker topic ingest actId = do
  r <- republish broker topic ingest actId
  case r of
    Left e -> hPutStrLn stderr ("[stub-kawa] republish failed: " <> e)
    Right () -> pure ()

-- | Re-assemble the envelope from the doorway request + minted id, and publish it with
-- kawa's producer shape (value = envelope JSON, key = @"<subject.type>:<subject.id>"@,
-- the @keiro-*@ header set).
republish :: Text -> Text -> IngestRequest -> Text -> IO (Either String ())
republish broker topic (IngestRequest {verb = vb, actor = ac, subject = sj, payload = pl, contextRefs = crs, sourceEventId = sevid, occurredAt = oat}) actId = do
  let Subject {kind = sty, subjectId = sid} = sj
      env =
        ActivityEnvelope
          { activityId = activityCoordinate actId,
            occurredAt = activityCoordinate oat,
            source = activityCoordinate "shinzui/shikigami",
            actor = ac,
            subject = sj,
            verb = activityCoordinate vb,
            payload = pl,
            contextRefs = crs,
            idempotencyKey = activityCoordinate sevid
          }
      -- keiro parses keiro-source-event-id as a UUID (EventId); our source_event_id
      -- is not a UUID, so we OMIT that optional header. The consumer dedupes on
      -- keiro-message-id (PreferIntegrationMessageId).
      headers =
        headersFromList
          [ ("keiro-message-id", TE.encodeUtf8 actId),
            ("keiro-source", "shinzui/kawa"),
            ("keiro-destination", TE.encodeUtf8 topic),
            ("keiro-event-type", "activity.recorded"),
            ("keiro-schema-version", "1"),
            ("content-type", "application/json"),
            ("keiro-occurred-at", TE.encodeUtf8 oat)
          ]
      record =
        ProducerRecord
          { prTopic = TopicName topic,
            prPartition = UnassignedPartition,
            prKey = Just (TE.encodeUtf8 (activityCoordinateText sty <> ":" <> activityCoordinateText sid)),
            prValue = Just (LBS.toStrict (encode env)),
            prHeaders = headers
          }
      props = brokersList [BrokerAddress broker]
  result <- runEff . runError @KafkaError . runKafkaProducer props $ do
    _ <- produceMessageSync record
    pure ()
  pure $ case result of
    Left _ -> Left "Kafka publish failed"
    Right () -> Right ()
