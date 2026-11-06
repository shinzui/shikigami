{-# LANGUAGE DataKinds #-}

-- | Retained watchdog ledger views. A view carries no observation authority.
module Shikigami.Watchdog.Ledger where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import Data.Char (isControl)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Objective.Types (ObjectiveId)
import Shikigami.Watchdog.Classify (SummaryDigest)
import Shikigami.Watchdog.Grant (GrantSnapshot, ObservationScope)
import Shikigami.Watchdog.Observation (CoverageCursor, PassCompletion)
import Shikigami.Watchdog.Types

data WatchdogError = SweepClaimHeld !SweepId | SweepMissing | SweepClosed | LedgerBindingConflict | LedgerCorrupt | LedgerBounds | IdentityPoolTooSmall | StaleObservation | IncompletePass
  deriving stock (Eq, Show)

data SweepOrigin = SweepOrigin
  { workflowName :: !WorkflowName,
    workflowId :: !WorkflowId,
    dueAt :: !UTCTime,
    principal :: !AgentIdentity
  }
  deriving stock (Eq, Show, Generic)

data SweepSummary = SweepSummary
  { observedAt :: !UTCTime,
    subjects :: !Word,
    refusals :: !Word,
    findings :: !Word,
    passCompleted :: !PassCompletion
  }
  deriving stock (Eq, Show, Generic)

data SweepView = SweepView
  { sweepId :: !SweepId,
    origin :: !SweepOrigin,
    grant :: !GrantSnapshot,
    claimKey :: !Text,
    openedAt :: !UTCTime,
    completedAt :: !(Maybe UTCTime),
    summary :: !(Maybe SweepSummary)
  }
  deriving stock (Eq, Show, Generic)

data Coverage = Coverage
  { cursor :: !CoverageCursor,
    passStartedAt :: !UTCTime,
    lastPassCompletedAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)

data SubjectIdentity = SubjectIdentity {subject :: !SubjectKey, episode :: !EpisodeId, finding :: !FindingId}
  deriving stock (Eq, Show, Generic)

newtype IdentityPool = IdentityPool [SubjectIdentity] deriving stock (Eq, Show)

newIdentityPool :: [Subject] -> IO IdentityPool
newIdentityPool subjects = IdentityPool <$> mapM allocate (nub subjects)
  where
    allocate subject = SubjectIdentity (subjectKey subject) <$> newEpisodeId <*> newFindingId

data PageOutcomeView = PageOutcomeView
  { notices :: ![FindingView],
    opened :: !Word,
    continued :: !Word,
    closed :: !Word
  }
  deriving stock (Eq, Show, Generic)

data ClosureReason = MadeProgress | LegitimatelyWaiting | OwnerTerminal | OwnerVanished
  deriving stock (Eq, Show)

data EpisodeView = EpisodeView
  { episodeId :: !EpisodeId,
    subject :: !Subject,
    objective :: !(Maybe ObjectiveId),
    kind :: !DetectionKind,
    family :: !DetectionFamily,
    openedAt :: !UTCTime,
    openedSweep :: !SweepId,
    closedAt :: !(Maybe UTCTime),
    closedReason :: !(Maybe ClosureReason),
    lastSummaryDigest :: !SummaryDigest,
    lastSeenSweep :: !SweepId,
    notifiedCount :: !Word
  }
  deriving stock (Eq, Show, Generic)

data PassOutcome = PassOutcome {closedEpisodes :: ![EpisodeId], unknownSubjects :: ![SubjectKey], complete :: !Bool}
  deriving stock (Eq, Show, Generic)

claimKeyFor :: AgentIdentity -> ObservationScope -> Text
claimKeyFor principal scope = versionedDigest "shikigami.watchdog-claim/1" (object ["principal" .= principal, "scope" .= scope])

familyFor :: DetectionKind -> DetectionFamily
familyFor DriftWork = DriftAssessmentFamily
familyFor _ = Liveness

familyText :: DetectionFamily -> Text
familyText Liveness = "liveness"
familyText DriftAssessmentFamily = "drift"

kindText :: DetectionKind -> Text
kindText StuckWork = "stuck"
kindText UnresolvedOutcome = "unresolved"
kindText StuckCoordinatorWork = "stuck-coordinator"
kindText DriftWork = "drift"

instance ToJSON SweepSummary where
  toJSON value = object ["observedAt" .= value.observedAt, "subjects" .= value.subjects, "refusals" .= value.refusals, "findings" .= value.findings, "passCompleted" .= value.passCompleted]

instance FromJSON SweepSummary where
  parseJSON = withObject "SweepSummary" \fields -> SweepSummary <$> fields .: "observedAt" <*> fields .: "subjects" <*> fields .: "refusals" <*> fields .: "findings" <*> fields .: "passCompleted"

instance ToJSON SweepView where
  toJSON value = object ["sweepId" .= value.sweepId, "origin" .= value.origin, "grant" .= value.grant, "claimKey" .= value.claimKey, "openedAt" .= value.openedAt, "completedAt" .= value.completedAt, "summary" .= value.summary]

instance FromJSON SweepView where
  parseJSON = withObject "SweepView" \fields -> SweepView <$> fields .: "sweepId" <*> fields .: "origin" <*> fields .: "grant" <*> fields .: "claimKey" <*> fields .: "openedAt" <*> fields .: "completedAt" <*> fields .: "summary"

instance ToJSON Coverage where
  toJSON value = object ["cursor" .= value.cursor, "passStartedAt" .= value.passStartedAt, "lastPassCompletedAt" .= value.lastPassCompletedAt]

instance FromJSON Coverage where
  parseJSON = withObject "Coverage" \fields -> Coverage <$> fields .: "cursor" <*> fields .: "passStartedAt" <*> fields .: "lastPassCompletedAt"

instance ToJSON PageOutcomeView where
  toJSON value = object ["notices" .= value.notices, "opened" .= value.opened, "continued" .= value.continued, "closed" .= value.closed]

instance FromJSON PageOutcomeView where
  parseJSON = withObject "PageOutcomeView" \fields -> PageOutcomeView <$> fields .: "notices" <*> fields .: "opened" <*> fields .: "continued" <*> fields .: "closed"

instance ToJSON EpisodeView where
  toJSON value = object ["episodeId" .= value.episodeId, "subject" .= value.subject, "objective" .= value.objective, "kind" .= value.kind, "family" .= value.family, "openedAt" .= value.openedAt, "openedSweep" .= value.openedSweep, "closedAt" .= value.closedAt, "closedReason" .= value.closedReason, "lastSummaryDigest" .= value.lastSummaryDigest, "lastSeenSweep" .= value.lastSeenSweep, "notifiedCount" .= value.notifiedCount]

instance FromJSON EpisodeView where
  parseJSON = withObject "EpisodeView" \fields -> EpisodeView <$> fields .: "episodeId" <*> fields .: "subject" <*> fields .: "objective" <*> fields .: "kind" <*> fields .: "family" <*> fields .: "openedAt" <*> fields .: "openedSweep" <*> fields .: "closedAt" <*> fields .: "closedReason" <*> fields .: "lastSummaryDigest" <*> fields .: "lastSeenSweep" <*> fields .: "notifiedCount"

instance ToJSON PassOutcome where
  toJSON value = object ["closedEpisodes" .= value.closedEpisodes, "unknownSubjects" .= value.unknownSubjects, "complete" .= value.complete]

instance FromJSON PassOutcome where
  parseJSON = withObject "PassOutcome" \fields -> PassOutcome <$> fields .: "closedEpisodes" <*> fields .: "unknownSubjects" <*> fields .: "complete"

instance ToJSON SweepOrigin where
  toJSON value = object ["workflowName" .= value.workflowName.unWorkflowName, "workflowId" .= value.workflowId.unWorkflowId, "dueAt" .= value.dueAt, "principal" .= value.principal]

instance FromJSON SweepOrigin where
  parseJSON = withObject "SweepOrigin" \fields ->
    SweepOrigin
      <$> (WorkflowName <$> (fields .: "workflowName" >>= coordinate 512))
      <*> (WorkflowId <$> (fields .: "workflowId" >>= coordinate 4096))
      <*> fields .: "dueAt"
      <*> fields .: "principal"
    where
      -- Native historical AgentRun names/ids contain separators rejected by
      -- Keiro's constructors for newly designed families. Preserve their exact
      -- bytes; this view neither derives an identity nor supplies authority.
      coordinate maximum value
        | not (Text.null value) && Text.length value <= maximum && not (Text.any isControl value) = pure value
        | otherwise = fail "invalid native watchdog origin coordinate"

instance ToJSON ClosureReason where
  toJSON =
    toJSON . \case
      MadeProgress -> ("progressing" :: Text)
      LegitimatelyWaiting -> "waiting"
      OwnerTerminal -> "terminal"
      OwnerVanished -> "vanished"

instance FromJSON ClosureReason where
  parseJSON = withText "ClosureReason" \case
    "progressing" -> pure MadeProgress
    "waiting" -> pure LegitimatelyWaiting
    "terminal" -> pure OwnerTerminal
    "vanished" -> pure OwnerVanished
    _ -> fail "unknown closure reason"

instance ToJSON WatchdogError where
  toJSON (SweepClaimHeld sweep) = object ["kind" .= ("claim-held" :: Text), "sweep" .= sweep]
  toJSON value =
    object
      [ "kind" .= case value of
          SweepMissing -> ("missing" :: Text)
          SweepClosed -> "closed"
          LedgerBindingConflict -> "binding-conflict"
          LedgerCorrupt -> "corrupt"
          LedgerBounds -> "bounds"
          IdentityPoolTooSmall -> "identity-pool"
          StaleObservation -> "stale-observation"
          IncompletePass -> "incomplete-pass"
      ]

instance FromJSON WatchdogError where
  parseJSON = withObject "WatchdogError" \fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "claim-held" -> SweepClaimHeld <$> fields .: "sweep"
      "missing" -> pure SweepMissing
      "closed" -> pure SweepClosed
      "binding-conflict" -> pure LedgerBindingConflict
      "corrupt" -> pure LedgerCorrupt
      "bounds" -> pure LedgerBounds
      "identity-pool" -> pure IdentityPoolTooSmall
      "stale-observation" -> pure StaleObservation
      "incomplete-pass" -> pure IncompletePass
      _ -> fail "unknown watchdog refusal"
