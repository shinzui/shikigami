{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Nominal execution coordinates and retained scalar evidence. These values
-- preserve wire spelling; owning admission still binds them to a concrete menu,
-- operation, policy, assignment and provider response.
module Shikigami.Execution.Coordinate
  ( ExecutionId,
    executionIdentity,
    ExecutionCoordinate,
    executionCoordinate,
    executionCoordinateText,
    ExecutionDigest,
    executionDigest,
    executionDigestFor,
    executionDigestText,
    ContextPosition,
    parseContextPosition,
    contextPositionNumber,
    ReplayContextFormat (..),
    ToolResultState (..),
    toolResultState,
    toolFailed,
    Retryability (..),
    retryability,
    failureIsRetryable,
    ExecutionGeneration,
    parseExecutionGeneration,
    executionGenerationInt,
    initialExecutionGeneration,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall (..))
import Dhall qualified
import GHC.Records (HasField (..))
import GHC.TypeLits (Symbol)
import Keiki.Shape (CanonicalTypeName (..))
import Shikigami.Decision.Contract (versionedDigest)

-- Keiro's mapped nominal representation is total, including its initial value.
-- The admitted snapshot owner checks the assignment-derived identity.
newtype ExecutionId = ExecutionId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

executionIdentity :: Text -> ExecutionId
executionIdentity = ExecutionId

instance CanonicalTypeName ExecutionId where
  canonicalTypeName _ = "shikigami.ExecutionId.v1"

type role ExecutionCoordinate nominal

newtype ExecutionCoordinate (scope :: Symbol) = ExecutionCoordinate Text
  deriving stock (Eq, Ord, Show)

executionCoordinate :: Text -> ExecutionCoordinate scope
executionCoordinate = ExecutionCoordinate

executionCoordinateText :: ExecutionCoordinate scope -> Text
executionCoordinateText (ExecutionCoordinate raw) = raw

instance ToJSON (ExecutionCoordinate scope) where
  toJSON = toJSON . executionCoordinateText
  toEncoding = toEncoding . executionCoordinateText

instance FromJSON (ExecutionCoordinate scope) where
  parseJSON value = ExecutionCoordinate <$> parseJSON value

instance FromDhall (ExecutionCoordinate scope) where
  autoWith _ = ExecutionCoordinate <$> Dhall.strictText

type role ExecutionDigest nominal

newtype ExecutionDigest (scope :: Symbol) = ExecutionDigest Text
  deriving stock (Eq, Ord, Show)

-- Exact commitment claims keep the owning protocol's existing grammar. In
-- particular, ephemeral execution records use the literal "ephemeral". Snapshot,
-- operation and provider owners retain their existing value/preimage checks.
executionDigest :: Text -> ExecutionDigest scope
executionDigest = ExecutionDigest

executionDigestFor :: Text -> Value -> ExecutionDigest scope
executionDigestFor domain = ExecutionDigest . versionedDigest domain

executionDigestText :: ExecutionDigest scope -> Text
executionDigestText (ExecutionDigest raw) = raw

instance ToJSON (ExecutionDigest scope) where
  toJSON = toJSON . executionDigestText
  toEncoding = toEncoding . executionDigestText

instance FromJSON (ExecutionDigest scope) where
  parseJSON value = ExecutionDigest <$> parseJSON value

newtype ContextPosition = ContextPosition Int
  deriving stock (Eq, Ord, Show)

parseContextPosition :: Int -> Either Text ContextPosition
parseContextPosition number
  | number >= 0 && number < 10000 = Right (ContextPosition number)
  | otherwise = Left "context position must be within 0..9999"

contextPositionNumber :: ContextPosition -> Int
contextPositionNumber (ContextPosition number) = number

instance ToJSON ContextPosition where
  toJSON = toJSON . contextPositionNumber
  toEncoding = toEncoding . contextPositionNumber

instance FromJSON ContextPosition where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseContextPosition

data ReplayContextFormat = LegacyContext | RequestContext deriving stock (Eq, Show)

instance ToJSON ReplayContextFormat where
  toJSON value = toJSON (case value of LegacyContext -> 1 :: Int; RequestContext -> 2)
  toEncoding value = toEncoding (case value of LegacyContext -> 1 :: Int; RequestContext -> 2)

instance FromJSON ReplayContextFormat where
  parseJSON value =
    parseJSON @Int value >>= \case
      1 -> pure LegacyContext
      2 -> pure RequestContext
      _ -> fail "unsupported replay context version"

data ToolResultState = ToolSucceeded | ToolFailed deriving stock (Eq, Show)

toolResultState :: Bool -> ToolResultState
toolResultState failed = if failed then ToolFailed else ToolSucceeded

toolFailed :: ToolResultState -> Bool
toolFailed = (== ToolFailed)

instance ToJSON ToolResultState where
  toJSON = toJSON . toolFailed
  toEncoding = toEncoding . toolFailed

instance FromJSON ToolResultState where
  parseJSON value = toolResultState <$> parseJSON value

data Retryability = RetryableFailure | PermanentFailure deriving stock (Eq, Show)

retryability :: Bool -> Retryability
retryability retryable = if retryable then RetryableFailure else PermanentFailure

failureIsRetryable :: Retryability -> Bool
failureIsRetryable = (== RetryableFailure)

instance ToJSON Retryability where
  toJSON = toJSON . failureIsRetryable
  toEncoding = toEncoding . failureIsRetryable

instance FromJSON Retryability where
  parseJSON value = retryability <$> parseJSON value

newtype ExecutionGeneration = ExecutionGeneration Int deriving stock (Eq, Ord, Show)

parseExecutionGeneration :: Int -> Either Text ExecutionGeneration
parseExecutionGeneration number
  | number >= 0 = Right (ExecutionGeneration number)
  | otherwise = Left "execution workflow generation must be nonnegative"

executionGenerationInt :: ExecutionGeneration -> Int
executionGenerationInt (ExecutionGeneration number) = number

initialExecutionGeneration :: ExecutionGeneration
initialExecutionGeneration = ExecutionGeneration 0

instance ToJSON ExecutionGeneration where
  toJSON = toJSON . executionGenerationInt
  toEncoding = toEncoding . executionGenerationInt

instance FromJSON ExecutionGeneration where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseExecutionGeneration

instance HasField "value" ExecutionId Text where
  getField (ExecutionId raw) = raw
