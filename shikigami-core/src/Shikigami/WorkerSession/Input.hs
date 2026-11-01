{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Checked continuing-session admission values.
module Shikigami.WorkerSession.Input
  ( WorkerSessionId (value),
    workerSessionId,
    sessionIdForScopeDigest,
    AssignmentId (value),
    parseAssignmentId,
    assignmentIdForDigest,
    SessionLimit (..),
    MaximumSessions,
    MaximumAssignments,
    MailboxLimit,
    AssignmentPageSize,
    EventPageSize,
    firstAssignmentPageSize,
    maximumSessionCapacity,
    InstructionText,
    parseInstructionText,
    instructionText,
    WorkerCoordinate,
    workerCoordinate,
    parseWorkerCoordinate,
    workerCoordinateText,
    WorkerCommitment,
    parseWorkerCommitment,
    workerCommitmentText,
    workerCommitmentFor,
    ArtifactReference,
    artifactReference,
    artifactReferenceText,
    ProviderReceipt,
    providerReceiptFor,
    parseProviderReceipt,
    providerReceiptText,
    ObjectiveActivity (..),
    objectiveIsActive,
    WorkflowGeneration,
    parseWorkflowGeneration,
    workflowGenerationInt,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value)
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUIDv5
import GHC.TypeLits (Symbol)
import Keiki.Shape (CanonicalTypeName (..))
import Shikigami.Decision.Contract (versionedDigest)

class SessionLimit a where
  sessionLimit :: a -> Int
  parseSessionLimit :: Integer -> Either Text a

bounded :: Text -> (Int -> a) -> Int -> Integer -> Either Text a
bounded name constructor upper value
  | value >= 1 && value <= toInteger upper = Right (constructor (fromInteger value))
  | otherwise = Left (name <> " must be within 1.." <> Text.pack (show upper))

newtype MaximumSessions = MaximumSessions Int
  deriving stock (Eq, Ord, Show)

instance SessionLimit MaximumSessions where
  sessionLimit (MaximumSessions value) = value
  parseSessionLimit = bounded "maximum sessions" MaximumSessions 128

instance ToJSON MaximumSessions where
  toJSON = toJSON . sessionLimit
  toEncoding = toEncoding . sessionLimit

instance FromJSON MaximumSessions where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseSessionLimit

newtype MaximumAssignments = MaximumAssignments Int
  deriving stock (Eq, Ord, Show)

instance SessionLimit MaximumAssignments where
  sessionLimit (MaximumAssignments value) = value
  parseSessionLimit = bounded "maximum assignments" MaximumAssignments 1000

instance ToJSON MaximumAssignments where
  toJSON = toJSON . sessionLimit
  toEncoding = toEncoding . sessionLimit

instance FromJSON MaximumAssignments where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseSessionLimit

newtype MailboxLimit = MailboxLimit Int
  deriving stock (Eq, Ord, Show)

instance SessionLimit MailboxLimit where
  sessionLimit (MailboxLimit value) = value
  parseSessionLimit = bounded "mailbox limit" MailboxLimit 128

instance ToJSON MailboxLimit where
  toJSON = toJSON . sessionLimit
  toEncoding = toEncoding . sessionLimit

instance FromJSON MailboxLimit where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseSessionLimit

maximumSessionCapacity :: MaximumSessions
maximumSessionCapacity = MaximumSessions 128

newtype InstructionText = InstructionText Text
  deriving stock (Eq)

instance Show InstructionText where
  show _ = "InstructionText <protected>"

parseInstructionText :: Text -> Either Text InstructionText
parseInstructionText value
  | Text.null (Text.strip value) = Left "instruction must not be blank"
  | ByteString.length (TextEncoding.encodeUtf8 value) > 1048576 = Left "instruction exceeds the payload ceiling"
  | otherwise = Right (InstructionText value)

instructionText :: InstructionText -> Text
instructionText (InstructionText value) = value

instance ToJSON InstructionText where
  toJSON = toJSON . instructionText
  toEncoding = toEncoding . instructionText

instance FromJSON InstructionText where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseInstructionText

-- The existing admission bound, with independent provider, locator and slot roles.
type role WorkerCoordinate nominal

newtype WorkerCoordinate (scope :: Symbol) = WorkerCoordinate Text
  deriving stock (Eq, Ord, Show)

-- Capture a provider/host claim; session admission still checks its bound.
workerCoordinate :: Text -> WorkerCoordinate scope
workerCoordinate = WorkerCoordinate

parseWorkerCoordinate :: Text -> Either Text (WorkerCoordinate scope)
parseWorkerCoordinate raw
  | not (Text.null raw) && Text.length raw <= 256 = Right (WorkerCoordinate raw)
  | otherwise = Left "worker coordinate must contain 1..256 characters"

workerCoordinateText :: WorkerCoordinate scope -> Text
workerCoordinateText (WorkerCoordinate raw) = raw

instance ToJSON (WorkerCoordinate scope) where
  toJSON = toJSON . workerCoordinateText
  toEncoding = toEncoding . workerCoordinateText

instance FromJSON (WorkerCoordinate scope) where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseWorkerCoordinate

type role WorkerCommitment nominal

newtype WorkerCommitment (scope :: Symbol) = WorkerCommitment Text
  deriving stock (Eq, Ord, Show)

parseWorkerCommitment :: Text -> Either Text (WorkerCommitment scope)
parseWorkerCommitment raw
  | Just suffix <- Text.stripPrefix "sha256:" raw,
    Text.length suffix == 64,
    Text.all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') suffix =
      Right (WorkerCommitment raw)
  | otherwise = Left "worker commitment requires sha256 and 64 lowercase hexadecimal digits"

workerCommitmentText :: WorkerCommitment scope -> Text
workerCommitmentText (WorkerCommitment raw) = raw

-- Producers retain their original versioned digest domains and canonical inputs.
workerCommitmentFor :: Text -> Value -> WorkerCommitment scope
workerCommitmentFor domain = WorkerCommitment . versionedDigest domain

instance ToJSON (WorkerCommitment scope) where
  toJSON = toJSON . workerCommitmentText
  toEncoding = toEncoding . workerCommitmentText

instance FromJSON (WorkerCommitment scope) where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseWorkerCommitment

-- Foreign published artifact coordinates are retained exactly, without assuming
-- ownership of the provider's locator grammar.
newtype ArtifactReference = ArtifactReference Text
  deriving stock (Eq, Ord, Show)

artifactReference :: Text -> ArtifactReference
artifactReference = ArtifactReference

artifactReferenceText :: ArtifactReference -> Text
artifactReferenceText (ArtifactReference raw) = raw

instance ToJSON ArtifactReference where
  toJSON = toJSON . artifactReferenceText
  toEncoding = toEncoding . artifactReferenceText

instance FromJSON ArtifactReference where
  parseJSON value = ArtifactReference <$> parseJSON value

newtype ProviderReceipt = ProviderReceipt Text
  deriving stock (Eq, Ord, Show)

parseProviderReceipt :: Text -> Either Text ProviderReceipt
parseProviderReceipt raw
  | Text.null raw = Left "provider receipt must not be empty"
  | otherwise = Right (ProviderReceipt raw)

providerReceiptText :: ProviderReceipt -> Text
providerReceiptText (ProviderReceipt raw) = raw

instance ToJSON ProviderReceipt where
  toJSON = toJSON . providerReceiptText
  toEncoding = toEncoding . providerReceiptText

instance FromJSON ProviderReceipt where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseProviderReceipt

data ObjectiveActivity = ObjectiveActive | ObjectiveInactive
  deriving stock (Eq, Show)

objectiveIsActive :: ObjectiveActivity -> Bool
objectiveIsActive ObjectiveActive = True
objectiveIsActive ObjectiveInactive = False

instance ToJSON ObjectiveActivity where
  toJSON = toJSON . objectiveIsActive
  toEncoding = toEncoding . objectiveIsActive

instance FromJSON ObjectiveActivity where
  parseJSON value = (\active -> if active then ObjectiveActive else ObjectiveInactive) <$> parseJSON value

providerReceiptFor :: Text -> Value -> ProviderReceipt
providerReceiptFor domain = ProviderReceipt . versionedDigest domain

-- Current Keiro exposes Int at its API; retain the nonnegative generation role.
newtype WorkflowGeneration = WorkflowGeneration Int
  deriving stock (Eq, Ord, Show)

parseWorkflowGeneration :: Int -> Either Text WorkflowGeneration
parseWorkflowGeneration number
  | number >= 0 = Right (WorkflowGeneration number)
  | otherwise = Left "workflow generation must be nonnegative"

workflowGenerationInt :: WorkflowGeneration -> Int
workflowGenerationInt (WorkflowGeneration number) = number

instance ToJSON WorkflowGeneration where
  toJSON = toJSON . workflowGenerationInt
  toEncoding = toEncoding . workflowGenerationInt

instance FromJSON WorkflowGeneration where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseWorkflowGeneration

-- This is the total mapped technical identity required by the Keiro nominal
-- contract. The session owner binds an admitted identity to its scope digest;
-- arbitrary carrier text is not admission authority.
newtype WorkerSessionId = WorkerSessionId {value :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

workerSessionId :: Text -> WorkerSessionId
workerSessionId = WorkerSessionId

sessionIdForScopeDigest :: WorkerCommitment "session-scope" -> WorkerSessionId
sessionIdForScopeDigest digest = WorkerSessionId (UUID.toText (UUIDv5.generateNamed UUIDv5.namespaceURL (ByteString.unpack (TextEncoding.encodeUtf8 ("shikigami.worker-session:" <> workerCommitmentText digest)))))

instance CanonicalTypeName WorkerSessionId where
  canonicalTypeName _ = "shikigami.WorkerSessionId.v1"

newtype AssignmentId = AssignmentId {value :: Text}
  deriving stock (Eq, Ord, Show)

parseAssignmentId :: Text -> Either Text AssignmentId
parseAssignmentId raw = case UUID.fromText raw of
  Just identifier
    | let (_, version, variant, _) = UUID.toWords identifier,
      raw == UUID.toText identifier,
      version .&. 0xf000 == 0x5000,
      variant .&. 0xc0000000 == 0x80000000 ->
        Right (AssignmentId raw)
  _ -> Left "assignment identity requires a canonical RFC 4122 UUIDv5"

assignmentIdForDigest :: Value -> AssignmentId
assignmentIdForDigest input = AssignmentId (UUID.toText (UUIDv5.generateNamed UUIDv5.namespaceURL (ByteString.unpack (TextEncoding.encodeUtf8 (versionedDigest "shikigami.worker-assignment/1" input)))))

instance ToJSON AssignmentId where
  toJSON (AssignmentId raw) = toJSON raw
  toEncoding (AssignmentId raw) = toEncoding raw

instance FromJSON AssignmentId where
  parseJSON input = parseJSON input >>= either (fail . Text.unpack) pure . parseAssignmentId

newtype AssignmentPageSize = AssignmentPageSize Int
  deriving stock (Eq, Ord, Show)

instance SessionLimit AssignmentPageSize where
  sessionLimit (AssignmentPageSize number) = number
  parseSessionLimit = bounded "assignment page size" AssignmentPageSize 20

instance ToJSON AssignmentPageSize where
  toJSON = toJSON . sessionLimit
  toEncoding = toEncoding . sessionLimit

instance FromJSON AssignmentPageSize where
  parseJSON input = parseJSON input >>= either (fail . Text.unpack) pure . parseSessionLimit

firstAssignmentPageSize :: AssignmentPageSize
firstAssignmentPageSize = AssignmentPageSize 1

newtype EventPageSize = EventPageSize Int
  deriving stock (Eq, Ord, Show)

instance SessionLimit EventPageSize where
  sessionLimit (EventPageSize number) = number
  parseSessionLimit = bounded "event page size" EventPageSize 100

instance ToJSON EventPageSize where
  toJSON = toJSON . sessionLimit
  toEncoding = toEncoding . sessionLimit

instance FromJSON EventPageSize where
  parseJSON input = parseJSON input >>= either (fail . Text.unpack) pure . parseSessionLimit
