-- | Distinct locators within an objective. These keys do not allocate entities.
module Shikigami.Objective.Keys
  ( CriterionKey,
    parseCriterionKey,
    criterionKeyText,
    EvidenceKey,
    parseEvidenceKey,
    evidenceKeyText,
    ObjectiveAssignmentId,
    parseObjectiveAssignmentId,
    objectiveAssignmentIdText,
    ArtifactRef,
    parseArtifactRef,
    artifactRefText,
    validKey,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import Data.Text (Text)
import Data.Text qualified as Text

newtype CriterionKey = CriterionKey Text
  deriving stock (Eq, Ord, Show)

newtype EvidenceKey = EvidenceKey Text
  deriving stock (Eq, Ord, Show)

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

newtype ObjectiveAssignmentId = ObjectiveAssignmentId Text
  deriving stock (Eq, Ord, Show)

newtype ArtifactRef = ArtifactRef Text
  deriving stock (Eq, Ord, Show)

parseObjectiveAssignmentId :: Text -> Either Text ObjectiveAssignmentId
parseObjectiveAssignmentId value
  | validKey value = Right (ObjectiveAssignmentId value)
  | otherwise = Left "invalid objective assignment key"

parseArtifactRef :: Text -> Either Text ArtifactRef
parseArtifactRef value
  | validKey value = Right (ArtifactRef value)
  | otherwise = Left "invalid artifact reference"

objectiveAssignmentIdText :: ObjectiveAssignmentId -> Text
objectiveAssignmentIdText (ObjectiveAssignmentId value) = value

artifactRefText :: ArtifactRef -> Text
artifactRefText (ArtifactRef value) = value

-- Preserve the established assignment-locator object codec.
instance ToJSON ObjectiveAssignmentId where
  toJSON value = object ["value" .= objectiveAssignmentIdText value]

instance FromJSON ObjectiveAssignmentId where
  parseJSON = withObject "objective assignment key" \fields -> do
    raw <- fields .: "value"
    either (fail . Text.unpack) pure (parseObjectiveAssignmentId raw)

instance ToJSON ArtifactRef where toJSON = toJSON . artifactRefText

instance FromJSON ArtifactRef where
  parseJSON = withText "artifact reference" (either (fail . Text.unpack) pure . parseArtifactRef)
