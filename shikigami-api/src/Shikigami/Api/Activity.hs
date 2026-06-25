module Shikigami.Api.Activity
  ( ActivityEnvelope (..),
    Actor (..),
    Subject (..),
    ContextRef (..),
  )
where

import Data.Aeson (Value)
import Shikigami.Prelude

-- aeson options that snake_case field names so the C1 wire keys round-trip.
activityOptions :: Options
activityOptions = defaultOptions {fieldLabelModifier = camelTo2 '_'}

data Actor = Actor
  { kind :: !Text, -- "human" | "agent" | "service"
    id :: !Text,
    session :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Actor where toJSON = genericToJSON activityOptions

instance FromJSON Actor where parseJSON = genericParseJSON activityOptions

data Subject = Subject {subjectType :: !Text, subjectId :: !Text}
  deriving stock (Eq, Show, Generic)

-- subjectType -> "type", subjectId -> "id" require a custom modifier:
subjectOptions :: Options
subjectOptions =
  defaultOptions
    { fieldLabelModifier = \f -> case f of
        "subjectType" -> "type"
        "subjectId" -> "id"
        other -> other
    }

instance ToJSON Subject where toJSON = genericToJSON subjectOptions

instance FromJSON Subject where parseJSON = genericParseJSON subjectOptions

data ContextRef = ContextRef {scheme :: !Text, ref :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ActivityEnvelope = ActivityEnvelope
  { activityId :: !Text, -- UUIDv7 string
    occurredAt :: !Text, -- RFC3339 timestamp
    source :: !Text, -- "shinzui/shikigami"
    actor :: !Actor,
    subject :: !Subject,
    verb :: !Text, -- past-tense dotted string
    payload :: !Value, -- free-form JSON body
    contextRefs :: ![ContextRef],
    idempotencyKey :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ActivityEnvelope where toJSON = genericToJSON activityOptions

instance FromJSON ActivityEnvelope where parseJSON = genericParseJSON activityOptions
