{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Nonnegative attempt counts retain their owner and meaning. Decrement is a
-- checked operation; malformed state cannot create a negative accounting count.
module Shikigami.Execution.Counter
  ( AttemptCount,
    parseAttemptCount,
    AttemptLimit,
    parseAttemptLimit,
    attemptLimitReached,
    attemptLimitExceeded,
    attemptNumber,
    noAttempts,
    nextAttempt,
    previousAttempt,
    CallOrdinal,
    parseCallOrdinal,
    nextCallOrdinal,
    callOrdinalNumber,
    callOrdinalInt64,
    callOrdinalCount,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.TypeLits (Symbol)
import Numeric.Natural (Natural)
import Shikigami.Execution.Quantity (ResourceAmount, amountUnits, parseResourceAmount)

type role AttemptCount nominal

newtype AttemptCount (scope :: Symbol) = AttemptCount Natural
  deriving stock (Eq, Ord, Show)

parseAttemptCount :: Integer -> Either Text (AttemptCount scope)
parseAttemptCount count
  | count >= 0 = Right (AttemptCount (fromInteger count))
  | otherwise = Left "attempt count must be nonnegative"

attemptNumber :: AttemptCount scope -> Integer
attemptNumber (AttemptCount count) = toInteger count

noAttempts :: AttemptCount scope
noAttempts = AttemptCount 0

nextAttempt :: AttemptCount scope -> AttemptCount scope
nextAttempt (AttemptCount count) = AttemptCount (count + 1)

previousAttempt :: AttemptCount scope -> Either Text (AttemptCount scope)
previousAttempt (AttemptCount count)
  | count > 0 = Right (AttemptCount (count - 1))
  | otherwise = Left "attempt count cannot be decremented below zero"

instance ToJSON (AttemptCount scope) where
  toJSON = toJSON . attemptNumber
  toEncoding = toEncoding . attemptNumber

instance FromJSON (AttemptCount scope) where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseAttemptCount

-- A finite admission ceiling retains the same unit scope as its counter.
-- Its int64 bound belongs to construction; the observed counter itself is a
-- nonnegative natural, with each storage owner enforcing its own write bound.
type role AttemptLimit nominal

newtype AttemptLimit (scope :: Symbol) = AttemptLimit ResourceAmount
  deriving stock (Eq, Ord, Show)

parseAttemptLimit :: Integer -> Either Text (AttemptLimit scope)
parseAttemptLimit = fmap AttemptLimit . parseResourceAmount

attemptLimitReached :: AttemptCount scope -> AttemptLimit scope -> Bool
attemptLimitReached count (AttemptLimit limit) = attemptNumber count >= amountUnits limit

attemptLimitExceeded :: AttemptCount scope -> AttemptLimit scope -> Bool
attemptLimitExceeded count (AttemptLimit limit) = attemptNumber count > amountUnits limit

instance ToJSON (AttemptLimit scope) where
  toJSON (AttemptLimit limit) = toJSON limit
  toEncoding (AttemptLimit limit) = toEncoding limit

instance FromJSON (AttemptLimit scope) where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseAttemptLimit

-- | A receipt's one-based position is distinct from the assignment's observed
-- count, whose initial value is zero. The SQL ordinal fits signed int64.
newtype CallOrdinal = CallOrdinal Int64
  deriving stock (Eq, Ord, Show)

parseCallOrdinal :: Integer -> Either Text CallOrdinal
parseCallOrdinal number
  | number > 0 && number <= toInteger (maxBound :: Int64) = Right (CallOrdinal (fromInteger number))
  | otherwise = Left "call ordinal must be positive and fit signed int64"

nextCallOrdinal :: AttemptCount "selection-calls" -> Either Text CallOrdinal
nextCallOrdinal count = parseCallOrdinal (attemptNumber count + 1)

callOrdinalNumber :: CallOrdinal -> Integer
callOrdinalNumber (CallOrdinal number) = toInteger number

callOrdinalInt64 :: CallOrdinal -> Int64
callOrdinalInt64 (CallOrdinal number) = number

callOrdinalCount :: CallOrdinal -> AttemptCount "selection-calls"
callOrdinalCount (CallOrdinal number) = AttemptCount (fromIntegral number)

instance ToJSON CallOrdinal where
  toJSON = toJSON . callOrdinalNumber
  toEncoding = toEncoding . callOrdinalNumber

instance FromJSON CallOrdinal where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseCallOrdinal
