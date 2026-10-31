-- | The caller's addressed-trigger deduplication key, distinct from a full run
-- coordinate and the HTTP API's separately bounded request key.
module Shikigami.Trigger.RequestKey (RequestKey, parseRequestKey, requestKeyText) where

import Data.Aeson (FromJSON (..), ToJSON, withText)
import Data.Text (Text)
import Data.Text qualified as Text

newtype RequestKey = RequestKey Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseRequestKey :: Text -> Either Text RequestKey
parseRequestKey value
  | Text.null value = Left "addressed request key must not be empty"
  | otherwise = Right (RequestKey value)

requestKeyText :: RequestKey -> Text
requestKeyText (RequestKey value) = value

instance FromJSON RequestKey where
  parseJSON = withText "addressed request key" (either (fail . Text.unpack) pure . parseRequestKey)
