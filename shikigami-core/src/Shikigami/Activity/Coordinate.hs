{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Exact source-issued activity coordinates. Routing compares these claims;
-- producers and the existing context-reference owner retain value validation.
module Shikigami.Activity.Coordinate
  ( ActivityCoordinate,
    activityCoordinate,
    activityCoordinateText,
    ActorKind (..),
    actorKindText,
    parseActorKind,
    ContextScheme (..),
    contextSchemeText,
    ContextReference,
    parseContextReference,
    contextReferenceText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall (..))
import Dhall qualified
import GHC.TypeLits (Symbol)

type role ActivityCoordinate nominal

newtype ActivityCoordinate (scope :: Symbol) = ActivityCoordinate Text
  deriving stock (Eq, Ord, Show)

activityCoordinate :: Text -> ActivityCoordinate scope
activityCoordinate = ActivityCoordinate

activityCoordinateText :: ActivityCoordinate scope -> Text
activityCoordinateText (ActivityCoordinate value) = value

instance ToJSON (ActivityCoordinate scope) where
  toJSON = toJSON . activityCoordinateText
  toEncoding = toEncoding . activityCoordinateText

instance FromJSON (ActivityCoordinate scope) where
  parseJSON value = ActivityCoordinate <$> parseJSON value

instance FromDhall (ActivityCoordinate scope) where
  autoWith _ = ActivityCoordinate <$> Dhall.strictText

data ActorKind = HumanActor | AgentActor | ServiceActor deriving stock (Eq, Show)

actorKindText :: ActorKind -> Text
actorKindText HumanActor = "human"
actorKindText AgentActor = "agent"
actorKindText ServiceActor = "service"

parseActorKind :: Text -> Either Text ActorKind
parseActorKind "human" = Right HumanActor
parseActorKind "agent" = Right AgentActor
parseActorKind "service" = Right ServiceActor
parseActorKind value = Left ("unknown activity actor kind: " <> value)

instance ToJSON ActorKind where toJSON = toJSON . actorKindText

instance FromJSON ActorKind where parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseActorKind

data ContextScheme = MoriContext | ReiContext | PlanContext | SignalContext | ConversationContext | ActivityContext deriving stock (Eq, Ord, Show)

contextSchemeText :: ContextScheme -> Text
contextSchemeText MoriContext = "mori://"
contextSchemeText ReiContext = "rei://"
contextSchemeText PlanContext = "plan://"
contextSchemeText SignalContext = "signal://"
contextSchemeText ConversationContext = "conversation://"
contextSchemeText ActivityContext = "activity://"

instance ToJSON ContextScheme where toJSON = toJSON . contextSchemeText

instance FromJSON ContextScheme where
  parseJSON value =
    parseJSON @Text value >>= \raw -> case lookup raw [(contextSchemeText scheme, scheme) | scheme <- [MoriContext, ReiContext, PlanContext, SignalContext, ConversationContext, ActivityContext]] of
      Just scheme -> pure scheme
      Nothing -> fail ("unknown context_refs scheme: " <> Text.unpack raw)

newtype ContextReference = ContextReference Text deriving stock (Eq, Ord, Show)

parseContextReference :: Text -> Either Text ContextReference
parseContextReference value
  | Text.null (Text.strip value) = Left "context_refs ref must not be empty"
  | Text.length value > 512 = Left "context_refs ref is too long"
  | otherwise = Right (ContextReference value)

contextReferenceText :: ContextReference -> Text
contextReferenceText (ContextReference value) = value

instance ToJSON ContextReference where toJSON = toJSON . contextReferenceText

instance FromJSON ContextReference where parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseContextReference
