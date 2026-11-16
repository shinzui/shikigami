{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}

-- | Bounded body-free owner observations. SQL stays with each owner; a page
-- uses one read-only repeatable-read snapshot. Incomplete relationships are
-- explicit and cannot establish the absence of activity.
module FlowPack.Watchdog.Observation
  ( ObservationBounds (..),
    defaultObservationBounds,
    SubjectKind (..),
    CoverageCursor (..),
    initialCursor,
    PassCompletion (..),
    ObservationRefusal (..),
    ObservationRefusalKind (..),
    ObservationError (..),
    SubjectMetadata (..),
    SubjectObservation (..),
    ObservationPage (..),
    pageShares,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Time (UTCTime)
import FlowPack.Watchdog.Grant
import FlowPack.Watchdog.Types
import FlowPack.Watchdog.Waiting qualified as Waiting
import GHC.Generics (Generic)
import Shikigami.Coordination.Observation qualified as Coordinator
import Shikigami.Duration (Duration, durationTime, remainingDuration)
import Shikigami.Execution.Observation qualified as Execution
import Shikigami.Execution.RootObservation qualified as Root
import Shikigami.Execution.Transcript qualified as ExecutionOwner
import Shikigami.Objective.Observation qualified as Objective
import Shikigami.Objective.Types qualified as ObjectiveOwner
import Shikigami.WorkerSession.Observation qualified as Session
import Shikigami.WorkerSession.Types qualified as SessionOwner
import Shikigami.Workspace.ProcessObservation qualified as Process

data ObservationBounds = ObservationBounds
  { statementTimeout :: !(Duration "watchdog-statement"),
    lockTimeout :: !(Duration "watchdog-lock")
  }
  deriving stock (Eq, Show, Generic)

defaultObservationBounds :: ObservationBounds
defaultObservationBounds = ObservationBounds (remainingDuration 2) (remainingDuration 0.25)

data SubjectKind = Objectives | Sessions | Executions
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data CoverageCursor = CoverageCursor
  { scope :: !(Maybe ObservationScope),
    objectives :: !(Maybe ObjectiveOwner.ObjectiveId),
    sessions :: !(Maybe SessionOwner.WorkerSessionId),
    executions :: !(Maybe ExecutionOwner.ExecutionId),
    exhausted :: ![SubjectKind],
    nextKind :: !SubjectKind,
    passClean :: !Bool
  }
  deriving stock (Eq, Show, Generic)

initialCursor :: CoverageCursor
initialCursor = CoverageCursor Nothing Nothing Nothing Nothing [] Objectives True

data PassCompletion = PassContinuing | PassCompleted | PassIncomplete
  deriving stock (Eq, Show)

data ObservationRefusalKind = CorruptMetadata | RelationshipUnknown
  deriving stock (Eq, Show)

data ObservationRefusal = ObservationRefusal
  { kind :: !SubjectKind,
    key :: !Text,
    reason :: !ObservationRefusalKind
  }
  deriving stock (Eq, Show, Generic)

data ObservationError = ObservationUnavailable | ObservationBoundsExceeded | ObservationCorruptKey
  deriving stock (Eq, Show)

data SubjectMetadata
  = ObjectiveMetadata !Objective.ObjectiveObservation !(Maybe Coordinator.CoordinatorObservation) ![Session.SessionObservation] ![Execution.ExecutionObservation]
  | SessionMetadata !Session.SessionObservation ![Execution.ExecutionObservation]
  | ExecutionMetadata !Execution.ExecutionObservation
  deriving stock (Eq, Show)

data SubjectObservation = SubjectObservation
  { subject :: !Subject,
    objective :: !(Maybe ObjectiveOwner.ObjectiveId),
    mark :: !ActivityMark,
    waits :: ![WaitingFact],
    evidence :: !(NonEmpty EvidenceRef),
    relationshipsComplete :: !Completeness,
    metadata :: !SubjectMetadata,
    roots :: ![Root.RootObservation],
    processes :: ![Process.ProcessObservation],
    workflows :: ![Waiting.WorkflowObservation],
    approvals :: ![Waiting.ApprovalObservation]
  }
  deriving stock (Eq, Show, Generic)

data ObservationPage = ObservationPage
  { observedAt :: !UTCTime,
    cursor :: !CoverageCursor,
    passCompleted :: !PassCompletion,
    subjects :: ![SubjectObservation],
    refusals :: ![ObservationRefusal]
  }
  deriving stock (Eq, Show, Generic)

-- | Rotate the fair share even for a budget of one. Exhausted populations stay
-- exhausted until the whole pass ends, so a busy kind cannot starve another.
pageShares :: Int -> CoverageCursor -> [(SubjectKind, Int)]
pageShares requested cursor = [(kind, length (filter (== kind) selected)) | kind <- [Objectives, Sessions, Executions]]
  where
    rotated = take 3 (dropWhile (/= cursor.nextKind) (cycle [Objectives, Sessions, Executions]))
    eligible = filter (`notElem` cursor.exhausted) rotated
    selected = if null eligible then [] else take (max 0 (min 96 requested)) (cycle eligible)

instance ToJSON ObservationBounds where
  toJSON value = object ["statementTimeout" .= value.statementTimeout, "lockTimeout" .= value.lockTimeout]

instance FromJSON ObservationBounds where
  parseJSON = withObject "ObservationBounds" \fields -> ObservationBounds <$> fields .: "statementTimeout" <*> fields .: "lockTimeout"

instance ToJSON CoverageCursor where
  toJSON value = object ["scope" .= value.scope, "objectives" .= value.objectives, "sessions" .= value.sessions, "executions" .= value.executions, "exhausted" .= value.exhausted, "nextKind" .= value.nextKind, "passClean" .= value.passClean]

instance FromJSON CoverageCursor where
  parseJSON = withObject "CoverageCursor" \fields -> CoverageCursor <$> fields .: "scope" <*> fields .: "objectives" <*> fields .: "sessions" <*> fields .: "executions" <*> fields .: "exhausted" <*> fields .: "nextKind" <*> fields .: "passClean"

instance ToJSON ObservationRefusal where
  toJSON value = object ["kind" .= value.kind, "key" .= value.key, "reason" .= value.reason]

instance FromJSON ObservationRefusal where
  parseJSON = withObject "ObservationRefusal" \fields -> ObservationRefusal <$> fields .: "kind" <*> fields .: "key" <*> fields .: "reason"

instance ToJSON SubjectObservation where
  toJSON value = object ["subject" .= value.subject, "objective" .= value.objective, "mark" .= value.mark, "waits" .= value.waits, "evidence" .= value.evidence, "relationshipsComplete" .= value.relationshipsComplete, "metadata" .= value.metadata, "roots" .= value.roots, "processes" .= value.processes, "workflows" .= value.workflows, "approvals" .= value.approvals]

instance FromJSON SubjectObservation where
  parseJSON = withObject "SubjectObservation" \fields -> SubjectObservation <$> fields .: "subject" <*> fields .: "objective" <*> fields .: "mark" <*> fields .: "waits" <*> fields .: "evidence" <*> fields .: "relationshipsComplete" <*> fields .: "metadata" <*> fields .: "roots" <*> fields .: "processes" <*> fields .: "workflows" <*> fields .: "approvals"

instance ToJSON ObservationPage where
  toJSON value = object ["observedAt" .= value.observedAt, "cursor" .= value.cursor, "passCompleted" .= value.passCompleted, "subjects" .= value.subjects, "refusals" .= value.refusals]

instance FromJSON ObservationPage where
  parseJSON = withObject "ObservationPage" \fields -> ObservationPage <$> fields .: "observedAt" <*> fields .: "cursor" <*> fields .: "passCompleted" <*> fields .: "subjects" <*> fields .: "refusals"

instance ToJSON SubjectKind where
  toJSON =
    toJSON . \case
      Objectives -> ("objectives" :: Text)
      Sessions -> ("sessions" :: Text)
      Executions -> ("executions" :: Text)

instance FromJSON SubjectKind where
  parseJSON = withText "SubjectKind" \case
    "objectives" -> pure Objectives
    "sessions" -> pure Sessions
    "executions" -> pure Executions
    _ -> fail "unknown SubjectKind"

instance ToJSON PassCompletion where
  toJSON =
    toJSON . \case
      PassContinuing -> ("continuing" :: Text)
      PassCompleted -> ("completed" :: Text)
      PassIncomplete -> ("incomplete" :: Text)

instance FromJSON PassCompletion where
  parseJSON = withText "PassCompletion" \case
    "continuing" -> pure PassContinuing
    "completed" -> pure PassCompleted
    "incomplete" -> pure PassIncomplete
    _ -> fail "unknown PassCompletion"

instance ToJSON ObservationRefusalKind where
  toJSON =
    toJSON . \case
      CorruptMetadata -> ("corrupt-metadata" :: Text)
      RelationshipUnknown -> ("relationship-unknown" :: Text)

instance FromJSON ObservationRefusalKind where
  parseJSON = withText "ObservationRefusalKind" \case
    "corrupt-metadata" -> pure CorruptMetadata
    "relationship-unknown" -> pure RelationshipUnknown
    _ -> fail "unknown ObservationRefusalKind"

instance ToJSON ObservationError where
  toJSON =
    toJSON . \case
      ObservationUnavailable -> ("unavailable" :: Text)
      ObservationBoundsExceeded -> ("bounds-exceeded" :: Text)
      ObservationCorruptKey -> ("corrupt-key" :: Text)

instance FromJSON ObservationError where
  parseJSON = withText "ObservationError" \case
    "unavailable" -> pure ObservationUnavailable
    "bounds-exceeded" -> pure ObservationBoundsExceeded
    "corrupt-key" -> pure ObservationCorruptKey
    _ -> fail "unknown ObservationError"

instance ToJSON SubjectMetadata where
  toJSON = \case
    ObjectiveMetadata objective coordinator sessions executions -> object ["kind" .= ("objective" :: Text), "objective" .= objective, "coordinator" .= coordinator, "sessions" .= sessions, "executions" .= executions]
    SessionMetadata session executions -> object ["kind" .= ("session" :: Text), "session" .= session, "executions" .= executions]
    ExecutionMetadata execution -> object ["kind" .= ("execution" :: Text), "execution" .= execution]

instance FromJSON SubjectMetadata where
  parseJSON = withObject "SubjectMetadata" \fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "objective" -> ObjectiveMetadata <$> fields .: "objective" <*> fields .: "coordinator" <*> fields .: "sessions" <*> fields .: "executions"
      "session" -> SessionMetadata <$> fields .: "session" <*> fields .: "executions"
      "execution" -> ExecutionMetadata <$> fields .: "execution"
      _ -> fail "unknown subject metadata kind"
