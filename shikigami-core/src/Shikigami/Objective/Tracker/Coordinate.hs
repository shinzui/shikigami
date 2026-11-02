{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Bounded, nominal coordinates. None of these values confers authority.
module Shikigami.Objective.Tracker.Coordinate
  ( TrackerCoordinate,
    parseCoordinate,
    coordinateText,
    TrackerConnectionId,
    TrackerBindingId,
    ConnectionIncarnation,
    ResourceId,
    ProviderRevision,
    MappingRevision,
    ProposalId,
    PublicationId,
    AttemptId,
    RemoteReceiptId,
    CredentialReference,
    TrackerDigest,
    trackerDigest,
    parseDigest,
    digestText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, withText)
import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.TypeLits (Symbol)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Objective.Keys (validKey)

type role TrackerCoordinate nominal

newtype TrackerCoordinate (scope :: Symbol) = TrackerCoordinate Text
  deriving stock (Eq, Ord)

-- Resource/credential identifiers can be sensitive. Explicit wire/SQL adapters
-- may unwrap them; exception diagnostics must not disclose them.
instance Show (TrackerCoordinate scope) where show _ = "TrackerCoordinate <protected>"

parseCoordinate :: Text -> Either Text (TrackerCoordinate scope)
parseCoordinate raw
  | validKey raw = Right (TrackerCoordinate raw)
  | otherwise = Left "tracker coordinate must contain 1..256 non-whitespace characters"

coordinateText :: TrackerCoordinate scope -> Text
coordinateText (TrackerCoordinate value) = value

instance ToJSON (TrackerCoordinate scope) where
  toJSON = toJSON . coordinateText
  toEncoding = toEncoding . coordinateText

instance FromJSON (TrackerCoordinate scope) where
  parseJSON = withText "tracker coordinate" (either (fail . Text.unpack) pure . parseCoordinate)

type TrackerConnectionId = TrackerCoordinate "connection"

type TrackerBindingId = TrackerCoordinate "binding"

type ConnectionIncarnation = TrackerCoordinate "connection-incarnation"

type ResourceId = TrackerCoordinate "resource"

type ProviderRevision = TrackerCoordinate "provider-revision"

type MappingRevision = TrackerCoordinate "mapping-revision"

type ProposalId = TrackerCoordinate "proposal"

type PublicationId = TrackerCoordinate "publication"

type AttemptId = TrackerCoordinate "attempt"

type RemoteReceiptId = TrackerCoordinate "remote-receipt"

type CredentialReference = TrackerCoordinate "credential-reference"

type role TrackerDigest nominal

newtype TrackerDigest (scope :: Symbol) = TrackerDigest Text
  deriving stock (Eq, Ord, Show)

trackerDigest :: Text -> Value -> TrackerDigest scope
trackerDigest domain = TrackerDigest . versionedDigest domain

parseDigest :: Text -> Either Text (TrackerDigest scope)
parseDigest raw
  | Just hexadecimal <- Text.stripPrefix "sha256:" raw,
    Text.length hexadecimal == 64 && Text.all (\c -> isDigit c && c <= '9' || isAsciiLower c && c <= 'f') hexadecimal =
      Right (TrackerDigest raw)
  | otherwise = Left "tracker digest must be a lowercase SHA-256 commitment"

digestText :: TrackerDigest scope -> Text
digestText (TrackerDigest value) = value

instance ToJSON (TrackerDigest scope) where
  toJSON = toJSON . digestText
  toEncoding = toEncoding . digestText

instance FromJSON (TrackerDigest scope) where
  parseJSON = withText "tracker digest" (either (fail . Text.unpack) pure . parseDigest)
