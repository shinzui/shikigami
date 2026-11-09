{-# LANGUAGE DataKinds #-}

-- | Versioned recurring authority. A wake contains locators, never instructions.
module Shikigami.Mandate.Types where

import Data.Aeson qualified as Aeson
import Data.Char (isAsciiLower, isDigit)
import Data.List (nub)
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Keiro.Workflow (WorkflowId (..))
import Shikigami.Coordination.Wake (Listener)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.Objective.Types hiding (CreateRequest)
import Shikigami.Prelude

newtype MandateId = MandateId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON)

instance FromJSON MandateId where
  parseJSON value = Aeson.parseJSON value >>= either (fail . Text.unpack) pure . parseMandateId

parseMandateId :: Text -> Either Text MandateId
parseMandateId value
  | Text.length value >= 1 && Text.length value <= 160 && Text.all (\c -> isAsciiLower c || isDigit c || c `elem` ("-_:" :: String)) value = Right (MandateId value)
  | otherwise = Left "mandate id must contain 1..160 lowercase letters, digits, -, _ or :"

-- | Read-only checkpoint supervision is useful without dispatching a model.
-- The continuing controller and fresh bounded cycle retain the same root.
data CycleMode = ContinuingCoordinator | FreshCycleRun
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Cadence = Cadence {seconds :: !Int, maximumSeconds :: !Int}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON Cadence where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

data StopCondition = UntilExpiry | WhenObjectiveTerminal
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- The first provider exposes a whole authoritative checkpoint, rather than
-- replaying individual historical edits as overdue work.
data EvidenceSource = CurrentObjectiveCheckpoint
  deriving stock (Eq, Show, Generic)

-- Keep this wire name stable independently of the constructor count. Generic
-- single-nullary encoding would otherwise expose an empty array to operators.
instance ToJSON EvidenceSource where
  toJSON CurrentObjectiveCheckpoint = Aeson.String "CurrentObjectiveCheckpoint"

instance FromJSON EvidenceSource where
  parseJSON = Aeson.withText "mandate evidence source" \value ->
    if value == "CurrentObjectiveCheckpoint" then pure CurrentObjectiveCheckpoint else fail "unsupported mandate evidence source"

data CreateRequest = CreateRequest
  { mandateId :: !MandateId,
    objectiveId :: !ObjectiveId,
    rootId :: !ExecutionRootId,
    scope :: ![ObjectiveAssignmentId],
    sources :: ![EvidenceSource],
    maximumEvents :: !Int,
    cadence :: !Cadence,
    expiresAt :: !UTCTime,
    mode :: !CycleMode,
    stopCondition :: !StopCondition
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON CreateRequest where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

data ScheduleUpdate = ScheduleUpdate {cadence :: !Cadence, expiresAt :: !UTCTime}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON ScheduleUpdate where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

data StopReason = Expired | Revoked | CancelledByCaller | ObjectiveFinished | RootStopped | OwnershipChanged
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Objective revision is a monotonic source cursor. The immutable revision
-- identity breaks ties; timestamps never decide evidence identity.
data Watermark = Watermark {revision :: !(StateRevision "objective"), identity :: !Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Cycle = Cycle
  { number :: !Integer,
    operationId :: !OperationId,
    checkpoint :: !Watermark,
    instructionsRevision :: !(StateRevision "objective-instructions"),
    criteriaRevision :: !(StateRevision "objective-criteria"),
    owner :: !AccessPrincipal,
    fences :: ![(ObjectiveAssignmentId, StateRevision "worker-owner")],
    rootId :: !ExecutionRootId,
    progress :: ![OperationId]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Mandate = Mandate
  { format :: !Int,
    admission :: !CreateRequest,
    authority :: !AccessPrincipal,
    owner :: !AccessPrincipal,
    revision :: !(StateRevision "mandate"),
    fence :: !(StateRevision "mandate-owner"),
    watermark :: !(Maybe Watermark),
    lastCycle :: !(Maybe Cycle),
    activeCycle :: !(Maybe Cycle),
    nextDue :: !(Maybe UTCTime),
    idleCount :: !Int,
    stopReason :: !(Maybe StopReason),
    unresolved :: ![UnresolvedOperation],
    wake :: !(Maybe Listener)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show Mandate where show _ = "Mandate <protected>"

validateSnapshot :: Mandate -> Either ObjectiveError ()
validateSnapshot state = do
  let request = state.admission
  unless (state.format == 1 && state.idleCount >= 0 && state.idleCount <= 20 && revisionNumber state.revision <= 1000000000) (Left ObjectiveUnavailable)
  unless (request.cadence.seconds >= 1 && request.cadence.maximumSeconds >= request.cadence.seconds && request.cadence.maximumSeconds <= 604800) (Left ObjectiveUnavailable)
  unless (not (null request.scope) && length request.scope <= 32 && nub request.scope == request.scope && request.sources == [CurrentObjectiveCheckpoint] && request.maximumEvents >= 1 && request.maximumEvents <= 100) (Left ObjectiveUnavailable)
  unless (isJust state.stopReason == isNothing state.nextDue && maybe True (<= request.expiresAt) state.nextDue) (Left ObjectiveUnavailable)
  forM_ (mapMaybe id [state.lastCycle, state.activeCycle]) \cycle -> unless (cycle.number > 0 && cycle.rootId == request.rootId && not (null cycle.progress) && length cycle.progress <= request.maximumEvents) (Left ObjectiveUnavailable)
  unless (fmap (.checkpoint) state.lastCycle == state.watermark) (Left ObjectiveUnavailable)

validateSchedule :: UTCTime -> Cadence -> UTCTime -> Either ObjectiveError ()
validateSchedule now cadence expiry = do
  unless (cadence.seconds >= 1 && cadence.maximumSeconds >= cadence.seconds && cadence.maximumSeconds <= 604800) (Left (ObjectiveInvalid "cadence must be 1..604800 seconds with a bounded maximum"))
  unless (expiry > now && expiry <= addUTCTime (366 * 86400) now) (Left (ObjectiveInvalid "recurrence requires future finite expiry within one year"))

validateRequest :: UTCTime -> CreateRequest -> Either ObjectiveError ()
validateRequest now request = do
  either (Left . ObjectiveInvalid) (const (Right ())) (parseMandateId request.mandateId.value)
  validateSchedule now request.cadence request.expiresAt
  unless (not (null request.scope) && length request.scope <= 32 && nub request.scope == request.scope) (Left (ObjectiveInvalid "mandate scope requires 1..32 distinct assignment ids"))
  unless (request.sources == [CurrentObjectiveCheckpoint] && request.maximumEvents >= 1 && request.maximumEvents <= 100) (Left (ObjectiveInvalid "require the current objective checkpoint source and a 1..100 event bound"))

backoff :: Cadence -> Int -> Int
backoff cadence idle = min cadence.maximumSeconds (cadence.seconds * (2 ^ min 20 (max 0 idle)))

mandateWorkflowId :: MandateId -> WorkflowId
mandateWorkflowId identifier = WorkflowId ("mandate:" <> identifier.value)
