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
    RunReference,
    runReference,
    runReferenceText,
    TurnReference,
    turnReference,
    turnReferenceText,
    OriginLabel,
    originLabel,
    originLabelText,
    AssignmentDigest,
    parseAssignmentDigest,
    assignmentDigestText,
    MutationFingerprint,
    parseMutationFingerprint,
    mutationFingerprintText,
    ObjectivePayloadDigest,
    parseObjectivePayloadDigest,
    objectivePayloadDigestText,
    assignmentDigestFor,
    creationFingerprint,
    commandFingerprint,
    objectivePayloadDigest,
    CallerId,
    parseCallerId,
    callerIdText,
    OperatorId,
    parseOperatorId,
    operatorIdText,
    ConversationRef,
    parseConversationRef,
    conversationRefText,
    IntentionRef,
    intentionRef,
    intentionRefText,
    ExecPlanRef,
    execPlanRef,
    execPlanRefText,
    ProtocolTaskRef,
    protocolTaskRef,
    protocolTaskRefText,
    ResultCommitment,
    resultCommitment,
    resultCommitmentText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Decision.Contract (versionedDigest)

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

-- Exact foreign references have no additional local grammar. Caller, operator
-- and conversation admission retain the existing validKey contract.

newtype CallerId = CallerId Text
  deriving stock (Eq, Ord, Show)

parseCallerId :: Text -> Either Text CallerId
parseCallerId value
  | validKey value = Right (CallerId value)
  | otherwise = Left "invalid callerId"

callerIdText :: CallerId -> Text
callerIdText (CallerId value) = value

instance ToJSON CallerId where
  toJSON = toJSON . callerIdText
  toEncoding = toEncoding . callerIdText

instance FromJSON CallerId where
  parseJSON = withText "callerId" (either (fail . Text.unpack) pure . parseCallerId)

newtype OperatorId = OperatorId Text
  deriving stock (Eq, Ord, Show)

parseOperatorId :: Text -> Either Text OperatorId
parseOperatorId value
  | validKey value = Right (OperatorId value)
  | otherwise = Left "invalid operatorId"

operatorIdText :: OperatorId -> Text
operatorIdText (OperatorId value) = value

instance ToJSON OperatorId where
  toJSON = toJSON . operatorIdText
  toEncoding = toEncoding . operatorIdText

instance FromJSON OperatorId where
  parseJSON = withText "operatorId" (either (fail . Text.unpack) pure . parseOperatorId)

newtype ConversationRef = ConversationRef Text
  deriving stock (Eq, Ord, Show)

parseConversationRef :: Text -> Either Text ConversationRef
parseConversationRef value
  | validKey value = Right (ConversationRef value)
  | otherwise = Left "invalid conversationRef"

conversationRefText :: ConversationRef -> Text
conversationRefText (ConversationRef value) = value

instance ToJSON ConversationRef where
  toJSON = toJSON . conversationRefText
  toEncoding = toEncoding . conversationRefText

instance FromJSON ConversationRef where
  parseJSON = withText "conversationRef" (either (fail . Text.unpack) pure . parseConversationRef)

newtype IntentionRef = IntentionRef Text
  deriving stock (Eq, Ord, Show)

intentionRef :: Text -> IntentionRef
intentionRef = IntentionRef

intentionRefText :: IntentionRef -> Text
intentionRefText (IntentionRef value) = value

instance ToJSON IntentionRef where
  toJSON = toJSON . intentionRefText
  toEncoding = toEncoding . intentionRefText

instance FromJSON IntentionRef where
  parseJSON = withText "intentionRef" (pure . intentionRef)

newtype ExecPlanRef = ExecPlanRef Text
  deriving stock (Eq, Ord, Show)

execPlanRef :: Text -> ExecPlanRef
execPlanRef = ExecPlanRef

execPlanRefText :: ExecPlanRef -> Text
execPlanRefText (ExecPlanRef value) = value

instance ToJSON ExecPlanRef where
  toJSON = toJSON . execPlanRefText
  toEncoding = toEncoding . execPlanRefText

instance FromJSON ExecPlanRef where
  parseJSON = withText "execPlanRef" (pure . execPlanRef)

newtype ProtocolTaskRef = ProtocolTaskRef Text
  deriving stock (Eq, Ord, Show)

protocolTaskRef :: Text -> ProtocolTaskRef
protocolTaskRef = ProtocolTaskRef

protocolTaskRefText :: ProtocolTaskRef -> Text
protocolTaskRefText (ProtocolTaskRef value) = value

instance ToJSON ProtocolTaskRef where
  toJSON = toJSON . protocolTaskRefText
  toEncoding = toEncoding . protocolTaskRefText

instance FromJSON ProtocolTaskRef where
  parseJSON = withText "protocolTaskRef" (pure . protocolTaskRef)

newtype ResultCommitment = ResultCommitment Text
  deriving stock (Eq, Ord, Show)

resultCommitment :: Text -> ResultCommitment
resultCommitment = ResultCommitment

resultCommitmentText :: ResultCommitment -> Text
resultCommitmentText (ResultCommitment value) = value

instance ToJSON ResultCommitment where
  toJSON = toJSON . resultCommitmentText
  toEncoding = toEncoding . resultCommitmentText

instance FromJSON ResultCommitment where
  parseJSON = withText "resultCommitment" (pure . resultCommitment)

-- Retained runtime locators and commitments preserve their original producer
-- recipes. They are not newly allocated entity identities.

newtype RunReference = RunReference Text
  deriving stock (Eq, Ord, Show)

runReference :: Text -> RunReference
runReference = RunReference

runReferenceText :: RunReference -> Text
runReferenceText (RunReference value) = value

instance ToJSON RunReference where
  toJSON = toJSON . runReferenceText
  toEncoding = toEncoding . runReferenceText

instance FromJSON RunReference where
  parseJSON = withText "runReference" (pure . runReference)

newtype TurnReference = TurnReference Text
  deriving stock (Eq, Ord, Show)

turnReference :: Text -> TurnReference
turnReference = TurnReference

turnReferenceText :: TurnReference -> Text
turnReferenceText (TurnReference value) = value

instance ToJSON TurnReference where
  toJSON = toJSON . turnReferenceText
  toEncoding = toEncoding . turnReferenceText

instance FromJSON TurnReference where
  parseJSON = withText "turnReference" (pure . turnReference)

newtype OriginLabel = OriginLabel Text
  deriving stock (Eq, Ord, Show)

originLabel :: Text -> OriginLabel
originLabel = OriginLabel

originLabelText :: OriginLabel -> Text
originLabelText (OriginLabel value) = value

instance ToJSON OriginLabel where
  toJSON = toJSON . originLabelText
  toEncoding = toEncoding . originLabelText

instance FromJSON OriginLabel where
  parseJSON = withText "originLabel" (pure . originLabel)

newtype AssignmentDigest = AssignmentDigest Text
  deriving stock (Eq, Ord, Show)

parseAssignmentDigest :: Text -> Either Text AssignmentDigest
parseAssignmentDigest value
  | validDigest value = Right (AssignmentDigest value)
  | otherwise = Left "invalid assignmentDigest"

assignmentDigestText :: AssignmentDigest -> Text
assignmentDigestText (AssignmentDigest value) = value

instance ToJSON AssignmentDigest where
  toJSON = toJSON . assignmentDigestText
  toEncoding = toEncoding . assignmentDigestText

instance FromJSON AssignmentDigest where
  parseJSON = withText "assignmentDigest" (either (fail . Text.unpack) pure . parseAssignmentDigest)

newtype MutationFingerprint = MutationFingerprint Text
  deriving stock (Eq, Ord, Show)

parseMutationFingerprint :: Text -> Either Text MutationFingerprint
parseMutationFingerprint value
  | validDigest value = Right (MutationFingerprint value)
  | otherwise = Left "invalid mutationFingerprint"

mutationFingerprintText :: MutationFingerprint -> Text
mutationFingerprintText (MutationFingerprint value) = value

instance ToJSON MutationFingerprint where
  toJSON = toJSON . mutationFingerprintText
  toEncoding = toEncoding . mutationFingerprintText

instance FromJSON MutationFingerprint where
  parseJSON = withText "mutationFingerprint" (either (fail . Text.unpack) pure . parseMutationFingerprint)

newtype ObjectivePayloadDigest = ObjectivePayloadDigest Text
  deriving stock (Eq, Ord, Show)

parseObjectivePayloadDigest :: Text -> Either Text ObjectivePayloadDigest
parseObjectivePayloadDigest value
  | validDigest value = Right (ObjectivePayloadDigest value)
  | otherwise = Left "invalid objectivePayloadDigest"

objectivePayloadDigestText :: ObjectivePayloadDigest -> Text
objectivePayloadDigestText (ObjectivePayloadDigest value) = value

instance ToJSON ObjectivePayloadDigest where
  toJSON = toJSON . objectivePayloadDigestText
  toEncoding = toEncoding . objectivePayloadDigestText

instance FromJSON ObjectivePayloadDigest where
  parseJSON = withText "objectivePayloadDigest" (either (fail . Text.unpack) pure . parseObjectivePayloadDigest)

validDigest :: Text -> Bool
validDigest value = Text.length value == 71 && "sha256:" `Text.isPrefixOf` value && Text.all hex (Text.drop 7 value)
  where
    hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

assignmentDigestFor :: (ToJSON a) => a -> AssignmentDigest
assignmentDigestFor = AssignmentDigest . versionedDigest "shikigami.objective-assignment-meaning/1"

creationFingerprint :: (ToJSON a) => a -> MutationFingerprint
creationFingerprint = MutationFingerprint . versionedDigest "shikigami.objective-create/1"

commandFingerprint :: (ToJSON a) => a -> MutationFingerprint
commandFingerprint = MutationFingerprint . versionedDigest "shikigami.objective-command/1"

objectivePayloadDigest :: (ToJSON a) => a -> ObjectivePayloadDigest
objectivePayloadDigest = ObjectivePayloadDigest . versionedDigest "shikigami.objective-payload/1"
