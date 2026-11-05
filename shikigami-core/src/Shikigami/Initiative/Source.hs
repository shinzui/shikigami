{-# LANGUAGE DataKinds #-}

-- | Closed per-source adapters from an @activity.v1@ envelope to a bounded
-- excerpt. A new channel is a code change, never a configuration entry.
module Shikigami.Initiative.Source
  ( sourceKindFor,
    observe,
  )
where

import Data.Aeson (Value (Object, String))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate (ActivityCoordinate, ActorKind (AgentActor), activityCoordinateText)
import Shikigami.Initiative.Types hiding (AgentActor)
import Shikigami.Initiative.Types qualified as Initiative
import Shikigami.Objective.Keys (ObservedSource (..))
import Shikigami.Trigger.Enqueue (envelopeOccurredAt)

sourceKindFor :: ActivityCoordinate "source" -> Maybe SourceKind
sourceKindFor source = case activityCoordinateText source of
  "external/intercom" -> Just IntercomConversation
  "external/transcripts" -> Just MeetingTranscript
  "fixture/chat" -> Just ChatFixture
  _ -> Nothing

-- | The instant is the caller's resolution for an envelope whose claim will not
-- parse, so this function reads no clock.
observe :: UTCTime -> ActivityEnvelope -> Either SkipReason Observed
observe fallback envelope = do
  case envelope.actor.kind of
    AgentActor -> Left Initiative.AgentActor
    _ -> Right ()
  kind <- maybe (Left UnsupportedSource) Right (sourceKindFor envelope.source)
  excerpt <- either (const (Left ExcerptTooShort)) Right (parseExcerpt (bounded (sanitized (documented kind envelope.payload))))
  pure
    Observed
      { activity = envelope.activityId,
        subject =
          ObservedSource
            { source = envelope.source,
              subjectKind = envelope.subject.kind,
              subjectId = envelope.subject.subjectId
            },
        kind,
        actor = envelope.actor,
        occurredAt = maybe fallback id (envelopeOccurredAt envelope),
        excerpt
      }

-- | A long transcript is still evidence: keep its head at a character boundary.
-- The digest is computed over this text, which marks the truncation.
bounded :: Text -> Text
bounded = Text.take 8192

-- | Channels deliver carriage returns and stray controls. They carry no meaning
-- here and are not worth refusing a message over.
sanitized :: Text -> Text
sanitized = Text.strip . Text.filter (\c -> not (isControl c) || c == '\n' || c == '\t')

-- | The payload path each channel documents, and only that path.
documented :: SourceKind -> Value -> Text
documented kind payload = case kind of
  IntercomConversation -> case (field "subject", field "body") of
    (Just subject, Just body) -> subject <> "\n" <> body
    (Nothing, Just body) -> body
    _ -> ""
  MeetingTranscript -> maybe "" id (field "transcript_text")
  ChatFixture -> maybe "" id (field "text")
  where
    field name = case payload of
      Object fields -> case KeyMap.lookup name fields of
        Just (String value) -> Just value
        _ -> Nothing
      _ -> Nothing
