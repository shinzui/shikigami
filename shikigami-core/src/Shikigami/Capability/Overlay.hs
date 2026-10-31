{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Public, serializable names and descriptors for additive model-tool
-- capability overlays. This module deliberately contains no live provider,
-- credential, endpoint, or acquisition handle.
module Shikigami.Capability.Overlay
  ( CapabilityId,
    CapabilityIdError (..),
    mkCapabilityId,
    capabilityIdText,
    CapabilityRevision,
    CapabilityRevisionError (..),
    mkCapabilityRevision,
    capabilityRevisionText,
    CapabilityOperationClass (..),
    CapabilityToolDescriptor (..),
    CapabilityDescriptor (..),
    ResolvedCapability,
    ResolvedCapabilitySet,
    mkResolvedCapabilitySet,
    emptyResolvedCapabilitySet,
    resolvedCapabilities,
  )
where

import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.List (sortOn)
import Data.Text qualified as Text
import Dhall (Decoder (..), FromDhall (..))
import Dhall qualified
import Shikigami.Prelude hiding ((.=))

newtype CapabilityId = CapabilityId Text
  deriving stock (Eq, Ord, Show)

newtype CapabilityIdError = CapabilityIdError {message :: Text}
  deriving stock (Eq, Show, Generic)

capabilityIdErrorMessage :: CapabilityIdError -> Text
capabilityIdErrorMessage CapabilityIdError {message} = message

-- | Construct a stable, lowercase dotted capability name. Hyphens are allowed
-- within names; empty segments created by consecutive dots are not.
mkCapabilityId :: Text -> Either CapabilityIdError CapabilityId
mkCapabilityId value
  | validStart && Text.all validRest remainder && not (".." `Text.isInfixOf` value) =
      Right (CapabilityId value)
  | otherwise =
      Left
        CapabilityIdError
          { message =
              "capability id must match [a-z][a-z0-9.-]* without consecutive dots; got "
                <> Text.pack (show value)
          }
  where
    (validStart, remainder) =
      case Text.uncons value of
        Nothing -> (False, "")
        Just (first, rest) -> (isAsciiLower first, rest)

    validRest character =
      isAsciiLower character
        || ('0' <= character && character <= '9')
        || character == '.'
        || character == '-'

    isAsciiLower character = 'a' <= character && character <= 'z'

capabilityIdText :: CapabilityId -> Text
capabilityIdText (CapabilityId value) = value

instance FromDhall CapabilityId where
  autoWith _ =
    let Decoder {extract = extractText, expected = expectedText} = Dhall.strictText
     in Decoder
          { extract = \expression ->
              case Dhall.toMonadic (extractText expression) of
                Left err -> Dhall.fromMonadic (Left err)
                Right value ->
                  either
                    (Dhall.extractError . capabilityIdErrorMessage)
                    pure
                    (mkCapabilityId value),
            expected = expectedText
          }

instance ToJSON CapabilityId where
  toJSON = Aeson.String . capabilityIdText

instance FromJSON CapabilityId where
  parseJSON = Aeson.withText "CapabilityId" \value ->
    either (fail . Text.unpack . capabilityIdErrorMessage) pure (mkCapabilityId value)

newtype CapabilityRevision = CapabilityRevision Text
  deriving stock (Eq, Ord, Show)

newtype CapabilityRevisionError = CapabilityRevisionError {message :: Text}
  deriving stock (Eq, Show, Generic)

capabilityRevisionErrorMessage :: CapabilityRevisionError -> Text
capabilityRevisionErrorMessage CapabilityRevisionError {message} = message

-- | Revisions are opaque, immutable operator-selected wire words. Their only
-- structural requirement is that they are not empty.
mkCapabilityRevision :: Text -> Either CapabilityRevisionError CapabilityRevision
mkCapabilityRevision value
  | Text.null value =
      Left CapabilityRevisionError {message = "capability revision must not be empty"}
  | otherwise = Right (CapabilityRevision value)

capabilityRevisionText :: CapabilityRevision -> Text
capabilityRevisionText (CapabilityRevision value) = value

instance ToJSON CapabilityRevision where
  toJSON = Aeson.String . capabilityRevisionText

instance FromJSON CapabilityRevision where
  parseJSON = Aeson.withText "CapabilityRevision" \value ->
    either (fail . Text.unpack . capabilityRevisionErrorMessage) pure (mkCapabilityRevision value)

data CapabilityOperationClass
  = Observation
  | IdempotentMutation
  | IrreversibleEmission
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON CapabilityOperationClass where
  toJSON =
    Aeson.String . \case
      Observation -> "Observation"
      IdempotentMutation -> "IdempotentMutation"
      IrreversibleEmission -> "IrreversibleEmission"

instance FromJSON CapabilityOperationClass where
  parseJSON = Aeson.withText "CapabilityOperationClass" \case
    "Observation" -> pure Observation
    "IdempotentMutation" -> pure IdempotentMutation
    "IrreversibleEmission" -> pure IrreversibleEmission
    value -> fail ("unknown capability operation class: " <> Text.unpack value)

data CapabilityToolDescriptor = CapabilityToolDescriptor
  { name :: !Text,
    operationClass :: !CapabilityOperationClass
  }
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON CapabilityToolDescriptor where
  toJSON CapabilityToolDescriptor {name, operationClass} =
    Aeson.object
      [ "name" .= name,
        "operationClass" .= operationClass
      ]

instance FromJSON CapabilityToolDescriptor where
  parseJSON = Aeson.withObject "CapabilityToolDescriptor" \value ->
    CapabilityToolDescriptor
      <$> value .: "name"
      <*> value .: "operationClass"

data CapabilityDescriptor = CapabilityDescriptor
  { capability :: !CapabilityId,
    revision :: !CapabilityRevision,
    tools :: ![CapabilityToolDescriptor]
  }
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON CapabilityDescriptor where
  toJSON CapabilityDescriptor {capability, revision, tools} =
    Aeson.object
      [ "capability" .= capability,
        "revision" .= revision,
        "tools" .= tools
      ]

instance FromJSON CapabilityDescriptor where
  parseJSON = Aeson.withObject "CapabilityDescriptor" \value ->
    CapabilityDescriptor
      <$> value .: "capability"
      <*> value .: "revision"
      <*> value .: "tools"

-- | A resolved capability is the complete public descriptor selected by the
-- operator catalog, not a live provider or lease.
type ResolvedCapability = CapabilityDescriptor

newtype ResolvedCapabilitySet = ResolvedCapabilitySet [ResolvedCapability]
  deriving stock (Eq, Show)

-- | Normalize a resolution snapshot by capability id so declaration order
-- cannot affect equality or serialized bytes.
mkResolvedCapabilitySet :: [ResolvedCapability] -> ResolvedCapabilitySet
mkResolvedCapabilitySet =
  ResolvedCapabilitySet
    . sortOn (\CapabilityDescriptor {capability} -> capability)

emptyResolvedCapabilitySet :: ResolvedCapabilitySet
emptyResolvedCapabilitySet = ResolvedCapabilitySet []

resolvedCapabilities :: ResolvedCapabilitySet -> [ResolvedCapability]
resolvedCapabilities (ResolvedCapabilitySet capabilities) = capabilities

instance ToJSON ResolvedCapabilitySet where
  toJSON = toJSON . resolvedCapabilities

instance FromJSON ResolvedCapabilitySet where
  parseJSON value = mkResolvedCapabilitySet <$> parseJSON value
