-- | Technical lease-owner tokens used with a monotonic attempt generation.
module Shikigami.Execution.Claim
  ( ClaimOwner,
    parseClaimOwner,
    claimOwnerText,
    claimOwnerFor,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID (UUID)
import Data.UUID qualified as UUID

newtype ClaimOwner = ClaimOwner Text
  deriving stock (Eq, Ord, Show)

parseClaimOwner :: Text -> Either Text ClaimOwner
parseClaimOwner value
  | not (Text.null value) && Text.length value <= 256 = Right (ClaimOwner value)
  | otherwise = Left "claim owner must contain 1..256 characters"

claimOwnerText :: ClaimOwner -> Text
claimOwnerText (ClaimOwner value) = value

-- UUID rendering is fixed-width; freshness is the executor's responsibility.
claimOwnerFor :: UUID -> ClaimOwner
claimOwnerFor = ClaimOwner . UUID.toText

instance ToJSON ClaimOwner where
  toJSON = toJSON . claimOwnerText
  toEncoding = toEncoding . claimOwnerText

instance FromJSON ClaimOwner where
  parseJSON = withText "claim owner" (either (fail . Text.unpack) pure . parseClaimOwner)
