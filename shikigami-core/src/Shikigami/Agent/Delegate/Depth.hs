-- | A nonnegative depth; the delegation policy separately bounds new children.
module Shikigami.Agent.Delegate.Depth
  ( DelegationDepth,
    parseDelegationDepth,
    initialDepth,
    nextDepth,
    depthInt,
  )
where

import Data.Aeson (FromJSON (..), ToJSON)
import Data.Text (Text)
import Data.Text qualified as Text

newtype DelegationDepth = DelegationDepth Int
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseDelegationDepth :: Integer -> Either Text DelegationDepth
parseDelegationDepth value
  | value >= 0 && value <= toInteger (maxBound :: Int) = Right (DelegationDepth (fromInteger value))
  | otherwise = Left "delegation depth must be a nonnegative native integer"

initialDepth :: DelegationDepth
initialDepth = DelegationDepth 0

nextDepth :: DelegationDepth -> Maybe DelegationDepth
nextDepth (DelegationDepth value)
  | value < maxBound = Just (DelegationDepth (value + 1))
  | otherwise = Nothing

depthInt :: DelegationDepth -> Int
depthInt (DelegationDepth value) = value

instance FromJSON DelegationDepth where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseDelegationDepth
