-- | The caller's HTTP idempotency key, distinct from a namespaced run key.
module Shikigami.AgentRun.RequestKey
  ( RequestKey,
    parseRequestKey,
    requestKeyText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as Text

newtype RequestKey = RequestKey Text
  deriving stock (Eq, Ord, Show)

parseRequestKey :: Text -> Either Text RequestKey
parseRequestKey value
  | not (Text.null value) && Text.length value <= 200 && not (Text.any isControl value) = Right (RequestKey value)
  | otherwise = Left "HTTP request key must contain 1..200 characters without control characters"

requestKeyText :: RequestKey -> Text
requestKeyText (RequestKey value) = value

instance ToJSON RequestKey where
  toJSON = toJSON . requestKeyText
  toEncoding = toEncoding . requestKeyText

instance FromJSON RequestKey where
  parseJSON = withText "HTTP request key" (either (fail . Text.unpack) pure . parseRequestKey)
