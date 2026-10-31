-- | Distinct locators within an objective. These keys do not allocate entities.
module Shikigami.Objective.Keys
  ( CriterionKey,
    parseCriterionKey,
    criterionKeyText,
    EvidenceKey,
    parseEvidenceKey,
    evidenceKeyText,
    validKey,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)

newtype CriterionKey = CriterionKey Text
  deriving stock (Eq, Ord, Show, Generic)

newtype EvidenceKey = EvidenceKey Text
  deriving stock (Eq, Ord, Show, Generic)

validKey :: Text -> Bool
validKey value = not (Text.null value) && Text.length value <= 256 && Text.all (\c -> c > ' ' && c /= '\DEL') value

parseCriterionKey :: Text -> Either Text CriterionKey
parseCriterionKey value
  | validKey value = Right (CriterionKey value)
  | otherwise = Left "invalid criterion key"

parseEvidenceKey :: Text -> Either Text EvidenceKey
parseEvidenceKey value
  | validKey value = Right (EvidenceKey value)
  | otherwise = Left "invalid evidence key"

criterionKeyText :: CriterionKey -> Text
criterionKeyText (CriterionKey value) = value

evidenceKeyText :: EvidenceKey -> Text
evidenceKeyText (EvidenceKey value) = value

instance ToJSON CriterionKey where toJSON = toJSON . criterionKeyText

instance FromJSON CriterionKey where
  parseJSON = withText "criterion key" (either (fail . Text.unpack) pure . parseCriterionKey)

instance ToJSON EvidenceKey where toJSON = toJSON . evidenceKeyText

instance FromJSON EvidenceKey where
  parseJSON = withText "evidence key" (either (fail . Text.unpack) pure . parseEvidenceKey)
