{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Body-free coordinates shared by observation, classification and delivery.
-- These records describe evidence; none grants command or observation authority.
module Shikigami.Watchdog.Types
  ( SweepId,
    parseSweepId,
    sweepIdText,
    newSweepId,
    EpisodeId,
    parseEpisodeId,
    episodeIdText,
    newEpisodeId,
    FindingId,
    parseFindingId,
    findingIdText,
    newFindingId,
    Subject (..),
    SubjectKey,
    subjectKey,
    subjectKeyText,
    parseSubjectKey,
    SessionActivity (..),
    ExecutionActivity (..),
    CoordinatorActivity (..),
    CoordinatorTerminal (..),
    ActivityMark (..),
    MarkDigest,
    markDigest,
    parseMarkDigest,
    markDigestText,
    WaitingReason (..),
    WaitingFact (..),
    Verdict (..),
    DetectionKind (..),
    DetectionFamily (..),
    DriftCategory (..),
    EvidenceRef (..),
    ObservedWindow (..),
    ObservationLimit (..),
    Completeness (..),
    FindingView (..),
    Windows (..),
    WatchdogLimit,
    parseWatchdogLimit,
    limitValue,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import Data.Bifunctor (first)
import Data.KindID.V7 qualified as KindID
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import GHC.TypeLits (Symbol)
import Shikigami.Agent.Approval (ReviewRequestId)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Duration (Duration)
import Shikigami.Execution.Coordinate (ExecutionId, executionIdText, executionIdentity)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.Execution.Progress (PendingReceiptCount)
import Shikigami.Execution.Transcript (ExecutionPhase)
import Shikigami.Objective.Types (ObjectiveAssignmentId, ObjectiveId, Status, objectiveIdText, parseObjectiveId)
import Shikigami.StateRevision (StateRevision)
import Shikigami.WorkerSession.Types (AssignmentPhase, SessionPhase, WorkerSessionId, workerSessionId, workerSessionIdText)
import Prelude hiding (until)

newtype SweepId = SweepId (KindID.KindID "shikigami_watchdog_sweep")
  deriving stock (Eq, Ord, Show)

parseSweepId :: Text -> Either Text SweepId
parseSweepId input = do
  value <- first (const "invalid SweepId encoding or prefix") (KindID.parseText @"shikigami_watchdog_sweep" input)
  case KindID.checkKindID value of
    Just _ -> Left "SweepId requires UUIDv7"
    Nothing
      | KindID.toText value == input -> Right (SweepId value)
      | otherwise -> Left "SweepId requires canonical encoding"

sweepIdText :: SweepId -> Text
sweepIdText (SweepId value) = KindID.toText value

newSweepId :: IO SweepId
newSweepId = SweepId <$> KindID.genKindID @"shikigami_watchdog_sweep"

instance ToJSON SweepId where toJSON = toJSON . sweepIdText

instance FromJSON SweepId where
  parseJSON = withText "SweepId" (either (fail . Text.unpack) pure . parseSweepId)

newtype EpisodeId = EpisodeId (KindID.KindID "shikigami_watchdog_episode")
  deriving stock (Eq, Ord, Show)

parseEpisodeId :: Text -> Either Text EpisodeId
parseEpisodeId input = do
  value <- first (const "invalid EpisodeId encoding or prefix") (KindID.parseText @"shikigami_watchdog_episode" input)
  case KindID.checkKindID value of
    Just _ -> Left "EpisodeId requires UUIDv7"
    Nothing
      | KindID.toText value == input -> Right (EpisodeId value)
      | otherwise -> Left "EpisodeId requires canonical encoding"

episodeIdText :: EpisodeId -> Text
episodeIdText (EpisodeId value) = KindID.toText value

newEpisodeId :: IO EpisodeId
newEpisodeId = EpisodeId <$> KindID.genKindID @"shikigami_watchdog_episode"

instance ToJSON EpisodeId where toJSON = toJSON . episodeIdText

instance FromJSON EpisodeId where
  parseJSON = withText "EpisodeId" (either (fail . Text.unpack) pure . parseEpisodeId)

newtype FindingId = FindingId (KindID.KindID "shikigami_watchdog_finding")
  deriving stock (Eq, Ord, Show)

parseFindingId :: Text -> Either Text FindingId
parseFindingId input = do
  value <- first (const "invalid FindingId encoding or prefix") (KindID.parseText @"shikigami_watchdog_finding" input)
  case KindID.checkKindID value of
    Just _ -> Left "FindingId requires UUIDv7"
    Nothing
      | KindID.toText value == input -> Right (FindingId value)
      | otherwise -> Left "FindingId requires canonical encoding"

findingIdText :: FindingId -> Text
findingIdText (FindingId value) = KindID.toText value

newFindingId :: IO FindingId
newFindingId = FindingId <$> KindID.genKindID @"shikigami_watchdog_finding"

instance ToJSON FindingId where toJSON = toJSON . findingIdText

instance FromJSON FindingId where
  parseJSON = withText "FindingId" (either (fail . Text.unpack) pure . parseFindingId)

data Subject
  = ObjectiveCoordinator !ObjectiveId
  | WorkerSession !WorkerSessionId
  | Execution !ExecutionId
  deriving stock (Eq, Ord, Show)

newtype SubjectKey = SubjectKey Text
  deriving stock (Eq, Ord, Show)

subjectKey :: Subject -> SubjectKey
subjectKey =
  SubjectKey . \case
    ObjectiveCoordinator value -> "coordinator/1/" <> objectiveIdText value
    WorkerSession value -> "session/1/" <> workerSessionIdText value
    Execution value -> "execution/1/" <> executionIdText value

subjectKeyText :: SubjectKey -> Text
subjectKeyText (SubjectKey value) = value

-- | Parsing returns the subject, so storage keys can only be minted by rendering
-- an owner coordinate. The suffix is preserved exactly, including any slashes.
parseSubjectKey :: Text -> Either Text Subject
parseSubjectKey value
  | Just raw <- Text.stripPrefix "coordinator/1/" value = ObjectiveCoordinator <$> parseObjectiveId raw
  | Just raw <- Text.stripPrefix "session/1/" value, not (Text.null raw) = Right (WorkerSession (workerSessionId raw))
  | Just raw <- Text.stripPrefix "execution/1/" value, not (Text.null raw) = Right (Execution (executionIdentity raw))
  | otherwise = Left "invalid watchdog subject key or version"

instance ToJSON SubjectKey where toJSON = toJSON . subjectKeyText

instance FromJSON SubjectKey where
  parseJSON = withText "SubjectKey" (either (fail . Text.unpack) (pure . subjectKey) . parseSubjectKey)

instance ToJSON Subject where toJSON = toJSON . subjectKey

instance FromJSON Subject where
  parseJSON = withText "Subject" (either (fail . Text.unpack) pure . parseSubjectKey)

data SessionActivity = SessionActivity
  { revision :: !(StateRevision "worker-session"),
    eventCursor :: !(StateRevision "worker-event"),
    consumedCursor :: !(StateRevision "worker-event"),
    nextSequence :: !(StateRevision "worker-message"),
    epoch :: !(StateRevision "worker-owner"),
    phase :: !SessionPhase,
    assignmentPhase :: !(Maybe AssignmentPhase)
  }
  deriving stock (Eq, Show, Generic)

data ExecutionActivity = ExecutionActivity
  { revision :: !(StateRevision "execution"),
    cursor :: !(StateRevision "execution-operation"),
    phase :: !ExecutionPhase,
    activeOperation :: !(Maybe OperationId),
    uncertainOperations :: !Word,
    pendingReceipts :: !PendingReceiptCount
  }
  deriving stock (Eq, Show, Generic)

data CoordinatorActivity = CoordinatorActivity
  { status :: !Status,
    revision :: !(StateRevision "objective"),
    latestDecision :: !(Maybe (StateRevision "objective")),
    listener :: !(Maybe (StateRevision "objective")),
    integratedCursors :: !Word,
    terminal :: !CoordinatorTerminal
  }
  deriving stock (Eq, Show, Generic)

data CoordinatorTerminal = CoordinatorOpen | CoordinatorTerminal
  deriving stock (Eq, Show)

data ActivityMark = SessionMark !SessionActivity | ExecutionMark !ExecutionActivity | CoordinatorMark !CoordinatorActivity
  deriving stock (Eq, Show)

newtype MarkDigest = MarkDigest Text
  deriving stock (Eq, Ord, Show)

markDigestText :: MarkDigest -> Text
markDigestText (MarkDigest value) = value

parseMarkDigest :: Text -> Either Text MarkDigest
parseMarkDigest value
  | Text.length value == 71,
    Just digits <- Text.stripPrefix "sha256:" value,
    Text.all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') digits =
      Right (MarkDigest value)
  | otherwise = Left "mark digest requires canonical sha256 hex"

markDigest :: ActivityMark -> MarkDigest
markDigest value = MarkDigest (versionedDigest "shikigami.watchdog-mark/1" value)

instance ToJSON MarkDigest where toJSON = toJSON . markDigestText

instance FromJSON MarkDigest where
  parseJSON = withText "MarkDigest" (either (fail . Text.unpack) pure . parseMarkDigest)

data WaitingReason
  = AwaitingApproval {until :: !UTCTime, review :: !ReviewRequestId}
  | AwaitingPermission {until :: !UTCTime}
  | RunningCommand {until :: !UTCTime, operationId :: !OperationId}
  | ParkedAssignment {since :: !UTCTime}
  | ObjectiveBlocked
  deriving stock (Eq, Show)

-- | An observation of parking has no timestamp until the mark ledger supplies it.
data WaitingFact
  = ApprovalWait !UTCTime !ReviewRequestId
  | PermissionWait !UTCTime
  | CommandWait !UTCTime !OperationId
  | AssignmentParked
  | BlockedObjective
  deriving stock (Eq, Show)

data Verdict = Progressing | Waiting !WaitingReason | Unresolved | Stuck | StuckCoordinator | Terminal | ObservationUnknown
  deriving stock (Eq, Show)

data DetectionKind = StuckWork | UnresolvedOutcome | StuckCoordinatorWork | DriftWork
  deriving stock (Eq, Ord, Show)

data DetectionFamily = Liveness | DriftAssessmentFamily
  deriving stock (Eq, Ord, Show)

data DriftCategory = WithinScope | PossibleDrift | OutsideScope
  deriving stock (Eq, Ord, Show)

data EvidenceRef
  = ObjectiveEvidence !ObjectiveId !(StateRevision "objective")
  | AssignmentEvidence !ObjectiveAssignmentId !(StateRevision "objective-assignment") !(StateRevision "worker-owner")
  | SessionEvidence !WorkerSessionId !(StateRevision "worker-event")
  | ExecutionEvidence !ExecutionId !(StateRevision "execution-operation")
  | DecisionEvidence !OperationId
  | ProcessEvidence !OperationId
  | RootEvidence !ExecutionRootId !(StateRevision "execution-root")
  | ApprovalEvidence !ReviewRequestId
  deriving stock (Eq, Show)

data ObservedWindow = ObservedWindow {firstSeenAt :: !UTCTime, lastChangedAt :: !UTCTime, observedAt :: !UTCTime}
  deriving stock (Eq, Show, Generic)

data ObservationLimit = ObservationLimit
  { subjectsPerSweep :: !(WatchdogLimit "subjects"),
    scopeComplete :: !Completeness,
    relationshipsComplete :: !Completeness
  }
  deriving stock (Eq, Show, Generic)

data Completeness = Complete | Unknown
  deriving stock (Eq, Show)

data FindingView = FindingView
  { findingId :: !FindingId,
    episodeId :: !EpisodeId,
    sweepId :: !SweepId,
    objective :: !(Maybe ObjectiveId),
    subject :: !Subject,
    kind :: !DetectionKind,
    evidence :: !(NonEmpty EvidenceRef),
    window :: !ObservedWindow,
    limit :: !ObservationLimit
  }
  deriving stock (Eq, Show, Generic)

data Windows = Windows
  { stuck :: !(Duration "watchdog-stuck"),
    parked :: !(Duration "watchdog-parked"),
    coordinator :: !(Duration "watchdog-coordinator"),
    drift :: !(Duration "watchdog-drift")
  }
  deriving stock (Eq, Show, Generic)

type role WatchdogLimit nominal

newtype WatchdogLimit (scope :: Symbol) = WatchdogLimit Int
  deriving stock (Eq, Ord, Show)

parseWatchdogLimit :: Int -> Either Text (WatchdogLimit scope)
parseWatchdogLimit value
  | value > 0 && value <= 16777216 = Right (WatchdogLimit value)
  | otherwise = Left "watchdog limits must be in 1..16777216"

limitValue :: WatchdogLimit scope -> Int
limitValue (WatchdogLimit value) = value

instance ToJSON (WatchdogLimit scope) where toJSON = toJSON . limitValue

instance FromJSON (WatchdogLimit scope) where
  parseJSON value = parseJSON @Int value >>= either (fail . Text.unpack) pure . parseWatchdogLimit

instance ToJSON SessionActivity where
  toJSON value = object ["revision" .= value.revision, "eventCursor" .= value.eventCursor, "consumedCursor" .= value.consumedCursor, "nextSequence" .= value.nextSequence, "epoch" .= value.epoch, "phase" .= value.phase, "assignmentPhase" .= value.assignmentPhase]

instance FromJSON SessionActivity where
  parseJSON = withObject "SessionActivity" \fields -> SessionActivity <$> fields .: "revision" <*> fields .: "eventCursor" <*> fields .: "consumedCursor" <*> fields .: "nextSequence" <*> fields .: "epoch" <*> fields .: "phase" <*> fields .: "assignmentPhase"

instance ToJSON ExecutionActivity where
  toJSON value = object ["revision" .= value.revision, "cursor" .= value.cursor, "phase" .= value.phase, "activeOperation" .= value.activeOperation, "uncertainOperations" .= value.uncertainOperations, "pendingReceipts" .= value.pendingReceipts]

instance FromJSON ExecutionActivity where
  parseJSON = withObject "ExecutionActivity" \fields -> ExecutionActivity <$> fields .: "revision" <*> fields .: "cursor" <*> fields .: "phase" <*> fields .: "activeOperation" <*> fields .: "uncertainOperations" <*> fields .: "pendingReceipts"

instance ToJSON CoordinatorActivity where
  toJSON value = object ["status" .= value.status, "revision" .= value.revision, "latestDecision" .= value.latestDecision, "listener" .= value.listener, "integratedCursors" .= value.integratedCursors, "terminal" .= value.terminal]

instance FromJSON CoordinatorActivity where
  parseJSON = withObject "CoordinatorActivity" \fields -> CoordinatorActivity <$> fields .: "status" <*> fields .: "revision" <*> fields .: "latestDecision" <*> fields .: "listener" <*> fields .: "integratedCursors" <*> fields .: "terminal"

instance ToJSON ObservedWindow where
  toJSON value = object ["firstSeenAt" .= value.firstSeenAt, "lastChangedAt" .= value.lastChangedAt, "observedAt" .= value.observedAt]

instance FromJSON ObservedWindow where
  parseJSON = withObject "ObservedWindow" \fields -> ObservedWindow <$> fields .: "firstSeenAt" <*> fields .: "lastChangedAt" <*> fields .: "observedAt"

instance ToJSON ObservationLimit where
  toJSON value = object ["subjectsPerSweep" .= value.subjectsPerSweep, "scopeComplete" .= value.scopeComplete, "relationshipsComplete" .= value.relationshipsComplete]

instance FromJSON ObservationLimit where
  parseJSON = withObject "ObservationLimit" \fields -> ObservationLimit <$> fields .: "subjectsPerSweep" <*> fields .: "scopeComplete" <*> fields .: "relationshipsComplete"

instance ToJSON FindingView where
  toJSON value = object ["findingId" .= value.findingId, "episodeId" .= value.episodeId, "sweepId" .= value.sweepId, "objective" .= value.objective, "subject" .= value.subject, "kind" .= value.kind, "evidence" .= value.evidence, "window" .= value.window, "limit" .= value.limit]

instance FromJSON FindingView where
  parseJSON = withObject "FindingView" \fields -> FindingView <$> fields .: "findingId" <*> fields .: "episodeId" <*> fields .: "sweepId" <*> fields .: "objective" <*> fields .: "subject" <*> fields .: "kind" <*> fields .: "evidence" <*> fields .: "window" <*> fields .: "limit"

instance ToJSON Windows where
  toJSON value = object ["stuck" .= value.stuck, "parked" .= value.parked, "coordinator" .= value.coordinator, "drift" .= value.drift]

instance FromJSON Windows where
  parseJSON = withObject "Windows" \fields -> Windows <$> fields .: "stuck" <*> fields .: "parked" <*> fields .: "coordinator" <*> fields .: "drift"

instance ToJSON CoordinatorTerminal where
  toJSON = \case
    CoordinatorOpen -> object ["kind" .= ("open" :: Text)]
    CoordinatorTerminal -> object ["kind" .= ("terminal" :: Text)]

instance FromJSON CoordinatorTerminal where
  parseJSON = withObject "CoordinatorTerminal" \fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "open" -> pure CoordinatorOpen
      "terminal" -> pure CoordinatorTerminal
      _ -> fail "unknown CoordinatorTerminal kind"

instance ToJSON ActivityMark where
  toJSON = \case
    SessionMark activity -> object ["kind" .= ("session" :: Text), "activity" .= activity]
    ExecutionMark activity -> object ["kind" .= ("execution" :: Text), "activity" .= activity]
    CoordinatorMark activity -> object ["kind" .= ("coordinator" :: Text), "activity" .= activity]

instance FromJSON ActivityMark where
  parseJSON = withObject "ActivityMark" \fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "session" -> SessionMark <$> fields .: "activity"
      "execution" -> ExecutionMark <$> fields .: "activity"
      "coordinator" -> CoordinatorMark <$> fields .: "activity"
      _ -> fail "unknown ActivityMark kind"

instance ToJSON WaitingReason where
  toJSON = \case
    AwaitingApproval until review -> object ["kind" .= ("approval" :: Text), "until" .= until, "review" .= review]
    AwaitingPermission until -> object ["kind" .= ("permission" :: Text), "until" .= until]
    RunningCommand until operationId -> object ["kind" .= ("command" :: Text), "until" .= until, "operationId" .= operationId]
    ParkedAssignment since -> object ["kind" .= ("parked" :: Text), "since" .= since]
    ObjectiveBlocked -> object ["kind" .= ("blocked" :: Text)]

instance FromJSON WaitingReason where
  parseJSON = withObject "WaitingReason" \fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "approval" -> AwaitingApproval <$> fields .: "until" <*> fields .: "review"
      "permission" -> AwaitingPermission <$> fields .: "until"
      "command" -> RunningCommand <$> fields .: "until" <*> fields .: "operationId"
      "parked" -> ParkedAssignment <$> fields .: "since"
      "blocked" -> pure ObjectiveBlocked
      _ -> fail "unknown WaitingReason kind"

instance ToJSON WaitingFact where
  toJSON = \case
    ApprovalWait until review -> object ["kind" .= ("approval" :: Text), "until" .= until, "review" .= review]
    PermissionWait until -> object ["kind" .= ("permission" :: Text), "until" .= until]
    CommandWait until operationId -> object ["kind" .= ("command" :: Text), "until" .= until, "operationId" .= operationId]
    AssignmentParked -> object ["kind" .= ("parked" :: Text)]
    BlockedObjective -> object ["kind" .= ("blocked" :: Text)]

instance FromJSON WaitingFact where
  parseJSON = withObject "WaitingFact" \fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "approval" -> ApprovalWait <$> fields .: "until" <*> fields .: "review"
      "permission" -> PermissionWait <$> fields .: "until"
      "command" -> CommandWait <$> fields .: "until" <*> fields .: "operationId"
      "parked" -> pure AssignmentParked
      "blocked" -> pure BlockedObjective
      _ -> fail "unknown WaitingFact kind"

instance ToJSON Verdict where
  toJSON = \case
    Progressing -> object ["kind" .= ("progressing" :: Text)]
    Waiting reason -> object ["kind" .= ("waiting" :: Text), "reason" .= reason]
    Unresolved -> object ["kind" .= ("unresolved" :: Text)]
    Stuck -> object ["kind" .= ("stuck" :: Text)]
    StuckCoordinator -> object ["kind" .= ("stuck-coordinator" :: Text)]
    Terminal -> object ["kind" .= ("terminal" :: Text)]
    ObservationUnknown -> object ["kind" .= ("unknown" :: Text)]

instance FromJSON Verdict where
  parseJSON = withObject "Verdict" \fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "progressing" -> pure Progressing
      "waiting" -> Waiting <$> fields .: "reason"
      "unresolved" -> pure Unresolved
      "stuck" -> pure Stuck
      "stuck-coordinator" -> pure StuckCoordinator
      "terminal" -> pure Terminal
      "unknown" -> pure ObservationUnknown
      _ -> fail "unknown Verdict kind"

instance ToJSON DetectionKind where
  toJSON = \case
    StuckWork -> object ["kind" .= ("stuck" :: Text)]
    UnresolvedOutcome -> object ["kind" .= ("unresolved" :: Text)]
    StuckCoordinatorWork -> object ["kind" .= ("stuck-coordinator" :: Text)]
    DriftWork -> object ["kind" .= ("drift" :: Text)]

instance FromJSON DetectionKind where
  parseJSON = withObject "DetectionKind" \fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "stuck" -> pure StuckWork
      "unresolved" -> pure UnresolvedOutcome
      "stuck-coordinator" -> pure StuckCoordinatorWork
      "drift" -> pure DriftWork
      _ -> fail "unknown DetectionKind kind"

instance ToJSON DetectionFamily where
  toJSON = \case
    Liveness -> object ["kind" .= ("liveness" :: Text)]
    DriftAssessmentFamily -> object ["kind" .= ("drift" :: Text)]

instance FromJSON DetectionFamily where
  parseJSON = withObject "DetectionFamily" \fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "liveness" -> pure Liveness
      "drift" -> pure DriftAssessmentFamily
      _ -> fail "unknown DetectionFamily kind"

instance ToJSON DriftCategory where
  toJSON = \case
    WithinScope -> object ["kind" .= ("within-scope" :: Text)]
    PossibleDrift -> object ["kind" .= ("possible-drift" :: Text)]
    OutsideScope -> object ["kind" .= ("outside-scope" :: Text)]

instance FromJSON DriftCategory where
  parseJSON = withObject "DriftCategory" \fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "within-scope" -> pure WithinScope
      "possible-drift" -> pure PossibleDrift
      "outside-scope" -> pure OutsideScope
      _ -> fail "unknown DriftCategory kind"

instance ToJSON Completeness where
  toJSON = \case
    Complete -> object ["kind" .= ("complete" :: Text)]
    Unknown -> object ["kind" .= ("unknown" :: Text)]

instance FromJSON Completeness where
  parseJSON = withObject "Completeness" \fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "complete" -> pure Complete
      "unknown" -> pure Unknown
      _ -> fail "unknown Completeness kind"

instance ToJSON EvidenceRef where
  toJSON = \case
    ObjectiveEvidence objective revision -> object ["kind" .= ("objective" :: Text), "objective" .= objective, "revision" .= revision]
    AssignmentEvidence assignment revision epoch -> object ["kind" .= ("assignment" :: Text), "assignment" .= assignment, "revision" .= revision, "epoch" .= epoch]
    SessionEvidence session cursor -> object ["kind" .= ("session" :: Text), "session" .= session, "cursor" .= cursor]
    ExecutionEvidence execution cursor -> object ["kind" .= ("execution" :: Text), "execution" .= execution, "cursor" .= cursor]
    DecisionEvidence operation -> object ["kind" .= ("decision" :: Text), "operation" .= operation]
    ProcessEvidence operation -> object ["kind" .= ("process" :: Text), "operation" .= operation]
    RootEvidence root revision -> object ["kind" .= ("root" :: Text), "root" .= root, "revision" .= revision]
    ApprovalEvidence review -> object ["kind" .= ("approval" :: Text), "review" .= review]

instance FromJSON EvidenceRef where
  parseJSON = withObject "EvidenceRef" \fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "objective" -> ObjectiveEvidence <$> fields .: "objective" <*> fields .: "revision"
      "assignment" -> AssignmentEvidence <$> fields .: "assignment" <*> fields .: "revision" <*> fields .: "epoch"
      "session" -> SessionEvidence <$> fields .: "session" <*> fields .: "cursor"
      "execution" -> ExecutionEvidence <$> fields .: "execution" <*> fields .: "cursor"
      "decision" -> DecisionEvidence <$> fields .: "operation"
      "process" -> ProcessEvidence <$> fields .: "operation"
      "root" -> RootEvidence <$> fields .: "root" <*> fields .: "revision"
      "approval" -> ApprovalEvidence <$> fields .: "review"
      _ -> fail "unknown EvidenceRef kind"
