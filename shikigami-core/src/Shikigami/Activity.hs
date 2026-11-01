{-# LANGUAGE DataKinds #-}

module Shikigami.Activity
  ( module Shikigami.Activity.Coordinate,
    ActivityId,
    ActivityEnvelope (..),
    Actor (..),
    Subject (..),
    ContextRef (..),
  )
where

import Data.Aeson (Value)
import Shikigami.Activity.Coordinate
import Shikigami.Prelude

-- aeson options that snake_case field names so the C1 wire keys round-trip.
activityOptions :: Options
activityOptions = defaultOptions {fieldLabelModifier = camelTo2 '_'}

data Actor = Actor
  { kind :: !ActorKind,
    id :: !(ActivityCoordinate "actor-id"),
    session :: !(Maybe (ActivityCoordinate "actor-session"))
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Actor where toJSON = genericToJSON activityOptions

instance FromJSON Actor where parseJSON = genericParseJSON activityOptions

data Subject = Subject {kind :: !(ActivityCoordinate "subject-kind"), subjectId :: !(ActivityCoordinate "subject-id")}
  deriving stock (Eq, Show, Generic)

-- kind -> "type", subjectId -> "id" require a custom modifier:
subjectOptions :: Options
subjectOptions =
  defaultOptions
    { fieldLabelModifier = \f -> case f of
        "kind" -> "type"
        "subjectId" -> "id"
        other -> other
    }

instance ToJSON Subject where toJSON = genericToJSON subjectOptions

instance FromJSON Subject where parseJSON = genericParseJSON subjectOptions

data ContextRef = ContextRef {scheme :: !ContextScheme, ref :: !ContextReference}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Published activities and synthetic non-stream triggers keep their existing
-- source-issued reference. This envelope does not allocate a second identity.
type ActivityId = ActivityCoordinate "activity-id"

data ActivityEnvelope = ActivityEnvelope
  { activityId :: !ActivityId,
    occurredAt :: !(ActivityCoordinate "occurred-at"), -- Raw timestamp claim; trigger intake owns reporting/fallback.
    source :: !(ActivityCoordinate "source"),
    actor :: !Actor,
    subject :: !Subject,
    verb :: !(ActivityCoordinate "verb"),
    payload :: !Value, -- free-form JSON body
    contextRefs :: ![ContextRef],
    idempotencyKey :: !(ActivityCoordinate "source-event-key")
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ActivityEnvelope where toJSON = genericToJSON activityOptions

instance FromJSON ActivityEnvelope where parseJSON = genericParseJSON activityOptions
