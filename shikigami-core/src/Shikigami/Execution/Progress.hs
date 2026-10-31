-- | Bounded durable progress counters. Counts and policy ceilings have
-- distinct nominal types; private constructors keep invalid state out of rows.
module Shikigami.Execution.Progress
  ( ProgressNumber (..),
    advanceProgress,
    previousProgress,
    modelTurnLimitReached,
    repairLimitReached,
    ModelTurnCount,
    RepairCount,
    PendingReceiptCount,
    noModelTurns,
    noRepairs,
    noPendingReceipts,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Execution.Policy.Limits (ModelTurnLimit, PolicyNumber (..), RepairLimit)

class ProgressNumber a where
  progressNumber :: a -> Integer
  parseProgress :: Integer -> Either Text a

advanceProgress :: (ProgressNumber a) => a -> Either Text a
advanceProgress = parseProgress . (+ 1) . progressNumber

previousProgress :: (ProgressNumber a) => a -> Either Text a
previousProgress = parseProgress . subtract 1 . progressNumber

bounded :: Text -> (Integer -> a) -> Integer -> Integer -> Either Text a
bounded name constructor maximumValue number
  | number >= 0 && number <= maximumValue = Right (constructor number)
  | otherwise = Left (name <> " must be within 0.." <> Text.pack (show maximumValue))

newtype ModelTurnCount = ModelTurnCount Integer
  deriving stock (Eq, Ord, Show)

instance ProgressNumber ModelTurnCount where
  progressNumber (ModelTurnCount number) = number
  parseProgress = bounded "model turn count" ModelTurnCount 10000

instance ToJSON ModelTurnCount where
  toJSON = toJSON . progressNumber
  toEncoding = toEncoding . progressNumber

instance FromJSON ModelTurnCount where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseProgress

noModelTurns :: ModelTurnCount
noModelTurns = ModelTurnCount 0

newtype RepairCount = RepairCount Integer
  deriving stock (Eq, Ord, Show)

instance ProgressNumber RepairCount where
  progressNumber (RepairCount number) = number
  parseProgress = bounded "repair count" RepairCount 10

instance ToJSON RepairCount where
  toJSON = toJSON . progressNumber
  toEncoding = toEncoding . progressNumber

instance FromJSON RepairCount where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseProgress

noRepairs :: RepairCount
noRepairs = RepairCount 0

newtype PendingReceiptCount = PendingReceiptCount Integer
  deriving stock (Eq, Ord, Show)

instance ProgressNumber PendingReceiptCount where
  progressNumber (PendingReceiptCount number) = number
  parseProgress = bounded "pending receipt count" PendingReceiptCount 1000000

instance ToJSON PendingReceiptCount where
  toJSON = toJSON . progressNumber
  toEncoding = toEncoding . progressNumber

instance FromJSON PendingReceiptCount where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseProgress

noPendingReceipts :: PendingReceiptCount
noPendingReceipts = PendingReceiptCount 0

modelTurnLimitReached :: ModelTurnCount -> ModelTurnLimit -> Bool
modelTurnLimitReached count limit = progressNumber count >= toInteger (policyNumber limit)

repairLimitReached :: RepairCount -> RepairLimit -> Bool
repairLimitReached count limit = progressNumber count >= toInteger (policyNumber limit)
