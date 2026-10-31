-- | A retained tool index, distinct from an execution-operation cursor.
module Shikigami.Execution.ToolPosition
  ( ToolPosition,
    parseToolPosition,
    toolPositionNumber,
    firstToolPosition,
    nextToolPosition,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Text (Text)
import Data.Text qualified as Text

newtype ToolPosition = ToolPosition Int
  deriving stock (Eq, Ord, Show)

parseToolPosition :: Integer -> Either Text ToolPosition
parseToolPosition value
  | value >= 0 && value < 256 = Right (ToolPosition (fromInteger value))
  | otherwise = Left "tool position must be within 0..255"

toolPositionNumber :: ToolPosition -> Int
toolPositionNumber (ToolPosition value) = value

firstToolPosition :: ToolPosition
firstToolPosition = ToolPosition 0

nextToolPosition :: ToolPosition -> Maybe ToolPosition
nextToolPosition (ToolPosition value)
  | value < 255 = Just (ToolPosition (value + 1))
  | otherwise = Nothing

instance ToJSON ToolPosition where
  toJSON = toJSON . toolPositionNumber
  toEncoding = toEncoding . toolPositionNumber

instance FromJSON ToolPosition where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseToolPosition
