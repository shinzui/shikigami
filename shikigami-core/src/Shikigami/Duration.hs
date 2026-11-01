{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Exact time spans with distinct policy roles. Existing owners retain range
-- admission and scheduling rules; lowering to clock/timeout units is explicit.
module Shikigami.Duration (Duration, parseDuration, remainingDuration, durationTime) where

import Data.Aeson (FromJSON (..), ToJSON)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import GHC.TypeLits (Symbol)

type role Duration nominal

newtype Duration (scope :: Symbol) = Duration NominalDiffTime
  deriving stock (Eq, Ord)
  deriving newtype (Show, ToJSON)

parseDuration :: NominalDiffTime -> Either Text (Duration scope)
parseDuration value
  | value >= 0 = Right (Duration value)
  | otherwise = Left "duration must be nonnegative"

-- | A remaining wait can be exhausted. Preserve immediate timeout at zero.
remainingDuration :: NominalDiffTime -> Duration scope
remainingDuration = Duration . max 0

instance FromJSON (Duration scope) where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseDuration

durationTime :: Duration scope -> NominalDiffTime
durationTime (Duration value) = value
