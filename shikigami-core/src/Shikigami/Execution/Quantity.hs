-- | Nonnegative resource units that fit the persisted int64 accounting contract.
-- Dimensions remain the keys of a quantity vector; no unchecked Num arithmetic
-- can construct a debit, refund or transport measurement.
module Shikigami.Execution.Quantity
  ( ResourceAmount,
    parseResourceAmount,
    amountUnits,
    zeroAmount,
    oneAmount,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text

newtype ResourceAmount = ResourceAmount Integer
  deriving stock (Eq, Ord, Show)

parseResourceAmount :: Integer -> Either Text ResourceAmount
parseResourceAmount amount
  | amount >= 0 && amount <= toInteger (maxBound :: Int64) = Right (ResourceAmount amount)
  | otherwise = Left "resource amount must fit nonnegative int64 units"

amountUnits :: ResourceAmount -> Integer
amountUnits (ResourceAmount amount) = amount

zeroAmount :: ResourceAmount
zeroAmount = ResourceAmount 0

oneAmount :: ResourceAmount
oneAmount = ResourceAmount 1

instance ToJSON ResourceAmount where
  toJSON = toJSON . amountUnits
  toEncoding = toEncoding . amountUnits

instance FromJSON ResourceAmount where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseResourceAmount
