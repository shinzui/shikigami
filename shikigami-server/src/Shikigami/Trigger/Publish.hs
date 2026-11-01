-- | The fixture publisher: produce ONE Activity Envelope onto the @activity.v1@ topic
-- with the exact @keiro-*@ header set the keiro inbox requires (IP-6 — identical to
-- EP-3's @stub-kawa --republish@). The message key is the envelope's @subject.id@.
-- Used by the @publish-fixture@ CLI to drive the stream trigger.
module Shikigami.Trigger.Publish
  ( publishEnvelope,
  )
where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Effectful (produceMessageSync, runKafkaProducer)
import Kafka.Producer (BrokerAddress (..), ProducePartition (UnassignedPartition), ProducerRecord (..), TopicName (..), brokersList)
import Kafka.Types (KafkaError, headersFromList)
import Shikigami.Activity (ActivityEnvelope (..), Subject (..))
import Shikigami.Activity.Coordinate (activityCoordinateText)
import Shikigami.Prelude

-- | Publish one envelope to the topic on the broker. Returns a typed error on failure.
publishEnvelope :: Text -> Text -> ActivityEnvelope -> IO (Either Text ())
publishEnvelope broker topic env = do
  let ActivityEnvelope {activityId = aid, source = src, verb = vb, occurredAt = oat, subject = subj} = env
      Subject {subjectId = sid} = subj
      -- NOTE: keiro parses keiro-source-event-id as a UUID (EventId), so we OMIT it
      -- (our idempotency_key is not a UUID). The consumer dedupes on keiro-message-id
      -- (PreferIntegrationMessageId), which is the envelope's activity_id.
      headers =
        headersFromList
          [ ("keiro-message-id", TE.encodeUtf8 (activityCoordinateText aid)),
            ("keiro-source", TE.encodeUtf8 (activityCoordinateText src)),
            ("keiro-destination", TE.encodeUtf8 topic),
            ("keiro-event-type", TE.encodeUtf8 (activityCoordinateText vb)),
            ("keiro-schema-version", "1"),
            ("content-type", "application/json"),
            ("keiro-occurred-at", TE.encodeUtf8 (activityCoordinateText oat))
          ]
      record =
        ProducerRecord
          { prTopic = TopicName topic,
            prPartition = UnassignedPartition,
            prKey = Just (TE.encodeUtf8 (activityCoordinateText sid)),
            prValue = Just (LBS.toStrict (encode env)),
            prHeaders = headers
          }
      props = brokersList [BrokerAddress broker]
  result <- runEff . runError @KafkaError . runKafkaProducer props $ do
    _ <- produceMessageSync record
    pure ()
  pure $ case result of
    Left (_cs, err) -> Left ("kafka publish: " <> Text.pack (show err))
    Right () -> Right ()
