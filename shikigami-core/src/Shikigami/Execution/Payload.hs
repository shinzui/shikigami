-- | Checked units in a protected-payload reference. A structurally valid
-- reference is still an untrusted locator until its owner verifies body,
-- digest, size, execution/session scope and replay authority together.
module Shikigami.Execution.Payload
  ( PayloadId,
    parsePayloadId,
    payloadIdText,
    PayloadDigest,
    parsePayloadDigest,
    payloadDigestText,
    PayloadByteCount,
    parsePayloadByteCount,
    payloadByteCount,
    payloadByteCountInt64,
  )
where

import Data.Aeson (FromJSON (..), ToJSON, withText)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text

-- | A bounded opaque store/ephemeral locator, not an allocated entity id.
newtype PayloadId = PayloadId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parsePayloadId :: Text -> Either Text PayloadId
parsePayloadId value
  | not (Text.null value) && Text.length value <= 256 && not (Text.any (< ' ') value) = Right (PayloadId value)
  | otherwise = Left "payload locator must contain 1..256 characters without C0 controls"

payloadIdText :: PayloadId -> Text
payloadIdText (PayloadId value) = value

newtype PayloadDigest = PayloadDigest Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parsePayloadDigest :: Text -> Either Text PayloadDigest
parsePayloadDigest value
  | Text.length value == 71 && "sha256:" `Text.isPrefixOf` value && Text.all hex (Text.drop 7 value) = Right (PayloadDigest value)
  | otherwise = Left "payload digest must be sha256 followed by 64 lowercase hexadecimal digits"
  where
    hex character = (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')

payloadDigestText :: PayloadDigest -> Text
payloadDigestText (PayloadDigest value) = value

-- | Encoded JSON has at least one byte. SQL's signed int64 is the shared
-- transport ceiling; each persistent owner separately enforces its 1 MiB body
-- ceiling. Ephemeral references do not acquire that persistence policy.
newtype PayloadByteCount = PayloadByteCount Integer
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parsePayloadByteCount :: Integer -> Either Text PayloadByteCount
parsePayloadByteCount value
  | value > 0 && value <= toInteger (maxBound :: Int64) = Right (PayloadByteCount value)
  | otherwise = Left "payload byte count must be positive and fit signed int64"

payloadByteCount :: PayloadByteCount -> Integer
payloadByteCount (PayloadByteCount value) = value

payloadByteCountInt64 :: PayloadByteCount -> Int64
payloadByteCountInt64 = fromInteger . payloadByteCount

instance FromJSON PayloadId where
  parseJSON = withText "payload locator" (either (fail . Text.unpack) pure . parsePayloadId)

instance FromJSON PayloadDigest where
  parseJSON = withText "payload digest" (either (fail . Text.unpack) pure . parsePayloadDigest)

instance FromJSON PayloadByteCount where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parsePayloadByteCount
