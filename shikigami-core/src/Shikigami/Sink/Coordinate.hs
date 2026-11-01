-- | Checked sink position and the native session coordinate retained by sinks.
module Shikigami.Sink.Coordinate
  ( SinkOrdinal,
    parseSinkOrdinal,
    sinkOrdinalInt,
    zeroSinkOrdinal,
    parseSinkSession,
  )
where

import Data.Aeson (FromJSON (..), ToJSON)
import Data.KindID.V7 qualified as KindID
import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.Id (SessionId, idText, parseId)

-- | A zero-based sink position. Receipts persist it in a PostgreSQL int4;
-- keep that existing bound on every platform rather than narrowing in SQL.
newtype SinkOrdinal = SinkOrdinal Int
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseSinkOrdinal :: Integer -> Either Text SinkOrdinal
parseSinkOrdinal value
  | value >= 0 && value <= 2147483647 = Right (SinkOrdinal (fromInteger value))
  | otherwise = Left "sink ordinal must be between zero and 2147483647"

sinkOrdinalInt :: SinkOrdinal -> Int
sinkOrdinalInt (SinkOrdinal value) = value

zeroSinkOrdinal :: SinkOrdinal
zeroSinkOrdinal = SinkOrdinal 0

instance FromJSON SinkOrdinal where
  parseJSON value = parseJSON @Integer value >>= either (fail . Text.unpack) pure . parseSinkOrdinal

-- | Keep Kioku's existing identity domain, including its prefix and canonical
-- renderer. The workflow/outbox identity is an independent coordinate.
parseSinkSession :: Text -> Either Text SessionId
parseSinkSession raw = do
  value <- parseId raw
  case KindID.checkKindID value of
    Just _ -> Left "sink session id requires UUIDv7"
    Nothing
      | idText value == raw -> Right value
      | otherwise -> Left "noncanonical sink session id"
