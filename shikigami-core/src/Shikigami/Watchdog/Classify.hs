{-# LANGUAGE DataKinds #-}

-- | Deterministic liveness from accepted owner marks. No clocks or effects.
module Shikigami.Watchdog.Classify
  ( PriorMark (..),
    Outcome (..),
    Detection (..),
    Observed (..),
    DeadlineKind (..),
    RootControl (..),
    EvidenceSummary (..),
    SummaryDigest,
    summaryDigest,
    summaryDigestText,
    parseSummaryDigest,
    classify,
    classifyPage,
    evidenceSummary,
    observedVerdict,
  )
where

import Control.Applicative ((<|>))
import Control.Lens ((&), (.~))
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import Data.Generics.Labels ()
import Data.List (nub, sort, sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Time (UTCTime, diffUTCTime)
import GHC.Generics (Generic)
import Shikigami.Coordination.Observation qualified as Coordinator
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Duration (durationTime)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Identity (ExecutionRootId, executionRootIdText)
import Shikigami.Execution.Observation qualified as Execution
import Shikigami.Execution.Resources (Cancellation, Overage)
import Shikigami.Execution.RootObservation qualified as Root
import Shikigami.Execution.Transcript qualified as Owner
import Shikigami.Objective.Observation qualified as ObjectiveObservation
import Shikigami.Objective.Types qualified as Objective
import Shikigami.StateRevision (StateRevision)
import Shikigami.Watchdog.Observation
import Shikigami.Watchdog.Types
import Shikigami.Watchdog.Waiting qualified as Waiting
import Shikigami.WorkerSession.Observation qualified as SessionObservation
import Shikigami.WorkerSession.Types qualified as Session
import Shikigami.Workspace.Process qualified as Process
import Shikigami.Workspace.ProcessObservation qualified as ProcessObservation

-- The exact prior is retained alongside the verdict for stale-input checks.
data PriorMark = PriorMark {digest :: !MarkDigest, firstSeenAt :: !UTCTime, lastChangedAt :: !UTCTime}
  deriving stock (Eq, Show, Generic)

data Outcome = Clear !Verdict | Detected !Detection
  deriving stock (Eq, Show)

data Detection = Detection
  { kind :: !DetectionKind,
    verdict :: !Verdict,
    summary :: !EvidenceSummary,
    evidence :: !(NonEmpty EvidenceRef),
    window :: !ObservedWindow,
    limit :: !ObservationLimit
  }
  deriving stock (Eq, Show, Generic)

data Observed = Observed
  { subject :: !Subject,
    objective :: !(Maybe Objective.ObjectiveId),
    mark :: !ActivityMark,
    prior :: !(Maybe PriorMark),
    outcome :: !Outcome
  }
  deriving stock (Eq, Show, Generic)

data DeadlineKind = ApprovalDeadline | PermissionDeadline | CommandDeadline | ParkedDeadline
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data RootControl = RootControl
  { rootId :: !ExecutionRootId,
    cancelled :: !Cancellation,
    overage :: !Overage,
    cutoffPassed :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data EvidenceSummary = EvidenceSummary
  { kind :: !DetectionKind,
    lapsed :: ![DeadlineKind],
    ownerEpoch :: !(Maybe (StateRevision "worker-owner")),
    roots :: ![RootControl],
    uncertainOperations :: !Word,
    driftCategory :: !(Maybe DriftCategory)
  }
  deriving stock (Eq, Show, Generic)

newtype SummaryDigest = SummaryDigest Text deriving stock (Eq, Ord, Show)

summaryDigest :: EvidenceSummary -> SummaryDigest
summaryDigest = SummaryDigest . versionedDigest "shikigami.watchdog-summary/1"

summaryDigestText :: SummaryDigest -> Text
summaryDigestText (SummaryDigest value) = value

parseSummaryDigest :: Text -> Either Text SummaryDigest
parseSummaryDigest value = SummaryDigest . markDigestText <$> parseMarkDigest value

instance ToJSON SummaryDigest where toJSON = toJSON . summaryDigestText

instance FromJSON SummaryDigest where parseJSON = withText "SummaryDigest" (either (fail . show) pure . parseSummaryDigest)

-- Rule order: terminal owner fact; incomplete evidence; first/changed mark;
-- legitimate wait; persistent uncertainty; coordinator; ordinary quiet work.
-- Unknown is a holding verdict, never evidence that an episode has cleared.
classify :: Windows -> UTCTime -> Maybe PriorMark -> SubjectObservation -> Observed
classify windows instant prior subject = Observed subject.subject subject.objective subject.mark prior outcome
  where
    outcome
      | terminal subject.mark = Clear Terminal
      | subject.relationshipsComplete == Unknown = Clear ObservationUnknown
      | maybe True ((/= markDigest subject.mark) . (.digest)) prior = Clear Progressing
      | Just reason <- liveWait = Clear (Waiting reason)
      | uncertainCount instant subject > 0 = if quiet >= durationTime windows.stuck then detected UnresolvedOutcome Unresolved else Clear Progressing
      | ObjectiveCoordinator _ <- subject.subject = coordinatorOutcome
      | quiet >= durationTime windows.stuck = detected StuckWork Stuck
      | otherwise = Clear Progressing
    since = maybe instant (.lastChangedAt) prior
    quiet = max 0 (diffUTCTime instant since)
    liveWait = listToMaybe (mapMaybe waiting waitingFacts)
    waitingFacts =
      subject.waits <> case subject.metadata of
        ObjectiveMetadata _ _ sessions executions ->
          [PermissionWait permission.expiresAt | execution <- executions, Just permission <- [execution.activePermission], permission.resolution == Nothing]
            <> [AssignmentParked | any (\session -> session.phase == Session.Parked || session.assignmentPhase == Just Session.AssignmentParked) sessions]
        _ -> []
    waiting (ApprovalWait deadline review) | deadline > instant = Just (AwaitingApproval deadline review)
    waiting (PermissionWait deadline) | deadline > instant = Just (AwaitingPermission deadline)
    waiting (CommandWait deadline operation) | deadline > instant = Just (RunningCommand deadline operation)
    waiting AssignmentParked | quiet < durationTime windows.parked && all ((> instant) . (.cutoff)) subject.roots = Just (ParkedAssignment since)
    waiting BlockedObjective = Just ObjectiveBlocked
    waiting _ = Nothing
    coordinatorOutcome = case subject.metadata of
      ObjectiveMetadata objective coordinator sessions executions
        | null objective.coordinators -> Clear Progressing
        | any (\session -> session.phase /= Session.Idle || session.queuedAssignments > 0) sessions -> Clear Progressing
        | any (\execution -> execution.phase `notElem` [Owner.Succeeded, Owner.Failed, Owner.Cancelled]) executions -> Clear Progressing
        | any (\header -> header.status == Waiting.HeaderRunning && maybe False (any ((== header.workflow.identifier) . (.runId)) . (.runs)) coordinator) subject.workflows -> Clear Progressing
        | quiet >= durationTime windows.coordinator -> detected StuckCoordinatorWork StuckCoordinator
        | otherwise -> Clear Progressing
      _ -> Clear ObservationUnknown
    detected kind verdict = case parseWatchdogLimit 1 of
      Left _ -> Clear ObservationUnknown
      Right budget -> Detected (Detection kind verdict (evidenceSummary windows instant since kind subject) subject.evidence (ObservedWindow (maybe instant (.firstSeenAt) prior) since instant) (ObservationLimit budget Unknown subject.relationshipsComplete))

classifyPage :: Windows -> ObservationPage -> Map SubjectKey PriorMark -> [Observed]
classifyPage windows page priors = map classifyOne page.subjects
  where
    classifyOne subject = case classify windows page.observedAt (Map.lookup (subjectKey subject.subject) priors) subject of
      observed -> case (observed.outcome, parseWatchdogLimit (max 1 (length page.subjects))) of
        (Detected detection, Right budget) -> observed & #outcome .~ Detected (detection & #limit . #subjectsPerSweep .~ budget & #limit . #scopeComplete .~ if page.passCompleted == PassCompleted then Complete else Unknown)
        _ -> observed

observedVerdict :: Observed -> Verdict
observedVerdict observed = case observed.outcome of Clear verdict -> verdict; Detected detection -> detection.verdict

terminal :: ActivityMark -> Bool
terminal (SessionMark mark) = mark.phase `elem` [Session.Failed, Session.Cancelled]
terminal (ExecutionMark mark) = mark.phase `elem` [Owner.Succeeded, Owner.Failed, Owner.Cancelled]
terminal (CoordinatorMark mark) = mark.terminal == CoordinatorTerminal || mark.status `elem` [Objective.Completed, Objective.Cancelled]

-- These fields deliberately exclude evidence revisions, sweep id and elapsed
-- time. Deadline kinds and cutoff transitions are meaningful changes.
evidenceSummary :: Windows -> UTCTime -> UTCTime -> DetectionKind -> SubjectObservation -> EvidenceSummary
evidenceSummary windows instant since kind subject = EvidenceSummary kind (sort (nub lapsed)) epoch roots (uncertainCount instant subject) Nothing
  where
    epoch = case subject.mark of SessionMark mark -> Just mark.epoch; _ -> Nothing
    roots = sortOn (executionRootIdText . (.rootId)) [RootControl root.rootId root.cancelled root.overage (root.cutoff <= instant) | root <- subject.roots]
    executions = executionsOf subject.metadata
    lapsed =
      [PermissionDeadline | execution <- executions, Just permission <- [execution.activePermission], permission.resolution == Nothing, permission.expiresAt <= instant]
        <> [CommandDeadline | process <- subject.processes, not process.receiptObserved, process.deadline <= instant]
        <> [ApprovalDeadline | approval <- subject.approvals, approval.phase == Waiting.ApprovalNoTimer || (approval.phase == Waiting.ApprovalPending && maybe False (<= instant) approval.until)]
        <> [ParkedDeadline | AssignmentParked `elem` subject.waits, diffUTCTime instant since >= durationTime windows.parked || any ((<= instant) . (.cutoff)) subject.roots]
        <> concatMap expired subject.waits
    expired (ApprovalWait deadline _) | deadline <= instant = [ApprovalDeadline]
    expired (PermissionWait deadline) | deadline <= instant = [PermissionDeadline]
    expired (CommandWait deadline _) | deadline <= instant = [CommandDeadline]
    expired _ = []

executionsOf :: SubjectMetadata -> [Execution.ExecutionObservation]
executionsOf (ObjectiveMetadata _ _ _ executions) = executions
executionsOf (SessionMetadata _ executions) = executions
executionsOf (ExecutionMetadata execution) = [execution]

uncertainCount :: UTCTime -> SubjectObservation -> Word
uncertainCount instant subject = max phaseCount detailed
  where
    detailed = sum [max execution.uncertainOperations (fromIntegral (length [operation | operation <- execution.operations, operation.uncertain == Owner.MarkedUncertain || any uncertainAttempt operation.attempts])) | execution <- executionsOf subject.metadata] + fromIntegral (length [process | process <- subject.processes, process.phase == Process.ProcessUnresolved])
    uncertainAttempt attempt = attempt.phase `elem` [Attempt.AttemptUncertain, Attempt.AttemptSuperseded] || (attempt.phase == Attempt.DispatchStarted && maybe True (<= instant) attempt.expiresAt)
    phaseCount = case subject.mark of
      SessionMark mark | mark.phase == Session.Unresolved || mark.assignmentPhase == Just Session.AssignmentUnresolved -> 1
      ExecutionMark mark | mark.phase == Owner.Unresolved -> max 1 mark.uncertainOperations
      _ -> case subject.metadata of ObjectiveMetadata objective _ _ _ -> objective.unresolvedOperations; _ -> 0

instance ToJSON PriorMark where
  toJSON value = object ["digest" .= value.digest, "firstSeenAt" .= value.firstSeenAt, "lastChangedAt" .= value.lastChangedAt]

instance FromJSON PriorMark where
  parseJSON = withObject "PriorMark" \fields -> PriorMark <$> fields .: "digest" <*> fields .: "firstSeenAt" <*> fields .: "lastChangedAt"

instance ToJSON Detection where
  toJSON value = object ["kind" .= value.kind, "verdict" .= value.verdict, "summary" .= value.summary, "evidence" .= value.evidence, "window" .= value.window, "limit" .= value.limit]

instance FromJSON Detection where
  parseJSON = withObject "Detection" \fields -> Detection <$> fields .: "kind" <*> fields .: "verdict" <*> fields .: "summary" <*> fields .: "evidence" <*> fields .: "window" <*> fields .: "limit"

instance ToJSON Observed where
  toJSON value = object ["subject" .= value.subject, "objective" .= value.objective, "mark" .= value.mark, "prior" .= value.prior, "outcome" .= value.outcome]

instance FromJSON Observed where
  parseJSON = withObject "Observed" \fields -> Observed <$> fields .: "subject" <*> fields .: "objective" <*> fields .: "mark" <*> fields .: "prior" <*> fields .: "outcome"

instance ToJSON RootControl where
  toJSON value = object ["rootId" .= value.rootId, "cancelled" .= value.cancelled, "overage" .= value.overage, "cutoffPassed" .= value.cutoffPassed]

instance FromJSON RootControl where
  parseJSON = withObject "RootControl" \fields -> RootControl <$> fields .: "rootId" <*> fields .: "cancelled" <*> fields .: "overage" <*> fields .: "cutoffPassed"

instance ToJSON EvidenceSummary where
  toJSON value = object ["kind" .= value.kind, "lapsed" .= value.lapsed, "ownerEpoch" .= value.ownerEpoch, "roots" .= value.roots, "uncertainOperations" .= value.uncertainOperations, "driftCategory" .= value.driftCategory]

instance FromJSON EvidenceSummary where
  parseJSON = withObject "EvidenceSummary" \fields -> EvidenceSummary <$> fields .: "kind" <*> fields .: "lapsed" <*> fields .: "ownerEpoch" <*> fields .: "roots" <*> fields .: "uncertainOperations" <*> fields .: "driftCategory"

instance ToJSON Outcome where
  toJSON (Clear verdict) = object ["clear" .= verdict]
  toJSON (Detected detection) = object ["detected" .= detection]

instance FromJSON Outcome where
  parseJSON = withObject "Outcome" \fields -> do
    (Clear <$> fields .: "clear") <|> (Detected <$> fields .: "detected")

instance ToJSON DeadlineKind where
  toJSON =
    toJSON . \case
      ApprovalDeadline -> ("approval" :: Text)
      PermissionDeadline -> "permission"
      CommandDeadline -> "command"
      ParkedDeadline -> "parked"

instance FromJSON DeadlineKind where
  parseJSON = withText "DeadlineKind" \case
    "approval" -> pure ApprovalDeadline
    "permission" -> pure PermissionDeadline
    "command" -> pure CommandDeadline
    "parked" -> pure ParkedDeadline
    _ -> fail "unknown deadline kind"
