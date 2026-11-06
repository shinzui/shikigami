{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}

-- | Separately bounded public Keiro reads. Only an exact approval-owner link
-- permits a timer lookup: generic timer or child-result scans are forbidden.
module Shikigami.Watchdog.Waiting
  ( WorkflowCoordinate (..),
    HeaderStatus (..),
    WorkflowObservation (..),
    ApprovalObservation (..),
    ApprovalPhase (..),
    WaitingPage (..),
    observeWaiting,
  )
where

import Control.Monad (forM)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, withText, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (nub)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import Effectful (Eff, IOE, liftIO, raise, (:>))
import Effectful.Error.Static (Error, tryError)
import Effectful.Timeout qualified as Timeout
import GHC.Generics (Generic)
import Keiro.Timer qualified as Timer
import Keiro.Workflow.Awakeable (AwakeableId)
import Keiro.Workflow.Instance qualified as Workflow
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Approval (ReviewRequestId, approvalTimeoutKind, reviewRequestIdText)
import Shikigami.Agent.Approval.Workflow (approvalWorkflowName)
import Shikigami.Approval.Observation (ApprovalAssociation (..))
import Shikigami.Duration (Duration, durationTime)
import Prelude hiding (until)

data WorkflowCoordinate = WorkflowCoordinate {name :: !Text, identifier :: !Text}
  deriving stock (Eq, Ord, Show, Generic)

data HeaderStatus = HeaderRunning | HeaderSuspended | HeaderCompleted | HeaderCancelled | HeaderFailed | HeaderAbsent | HeaderUnavailable
  deriving stock (Eq, Show)

data WorkflowObservation = WorkflowObservation
  { workflow :: !WorkflowCoordinate,
    generation :: !(Maybe Int),
    status :: !HeaderStatus,
    observedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

data ApprovalPhase = ApprovalPending | ApprovalNoTimer | ApprovalTerminal | ApprovalParentInactive | ApprovalUnavailable
  deriving stock (Eq, Show)

data ApprovalObservation = ApprovalObservation
  { review :: !ReviewRequestId,
    parent :: !WorkflowCoordinate,
    until :: !(Maybe UTCTime),
    phase :: !ApprovalPhase,
    observedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

data WaitingPage = WaitingPage
  { workflows :: ![WorkflowObservation],
    approvals :: ![ApprovalObservation],
    unknownParents :: ![WorkflowCoordinate]
  }
  deriving stock (Eq, Show, Generic)

type WaitingEffects es = (IOE :> es, Store :> es, Error StoreError :> es)

-- | At most 32 parent headers, 32 approval headers and 32 exact timer queries.
-- Every public call has its own finite timeout. Header and timer observations
-- retain their separate times; only structured projections leave this module.
observeWaiting :: (WaitingEffects es) => Duration "watchdog-statement" -> [WorkflowCoordinate] -> [ApprovalAssociation] -> Eff es WaitingPage
observeWaiting timeout requested associations = do
  let parents = take 32 (nub requested)
      omitted = drop 32 (nub requested)
      selected = take 32 [association | association <- associations, WorkflowCoordinate association.parentName association.parentId `elem` parents]
      overflow = [WorkflowCoordinate association.parentName association.parentId | association <- drop 32 [association | association <- associations, WorkflowCoordinate association.parentName association.parentId `elem` parents]]
  workflows <- forM parents (readHeader timeout)
  assessed <- forM selected \association -> do
    let parent = WorkflowCoordinate association.parentName association.parentId
        child = WorkflowCoordinate approvalWorkflowName.unWorkflowName (reviewRequestIdText association.review)
    case filter ((== parent) . (.workflow)) workflows of
      [owner] | owner.status == HeaderUnavailable -> pure (Just (ApprovalObservation association.review parent Nothing ApprovalUnavailable owner.observedAt), Just parent)
      [owner] | owner.status `notElem` [HeaderRunning, HeaderSuspended] -> pure (Just (ApprovalObservation association.review parent Nothing ApprovalParentInactive owner.observedAt), Nothing)
      _ -> do
        header <- readHeader timeout child
        case header.status of
          HeaderRunning -> timerFor parent association.review
          HeaderSuspended -> timerFor parent association.review
          HeaderUnavailable -> pure (Just (ApprovalObservation association.review parent Nothing ApprovalUnavailable header.observedAt), Just parent)
          HeaderAbsent -> pure (Just (ApprovalObservation association.review parent Nothing ApprovalNoTimer header.observedAt), Nothing)
          _ -> pure (Just (ApprovalObservation association.review parent Nothing ApprovalTerminal header.observedAt), Nothing)
  pure (WaitingPage workflows (catMaybes (map fst assessed)) (nub (omitted <> overflow <> [observation.workflow | observation <- workflows, observation.status == HeaderUnavailable] <> catMaybes (map snd assessed))))
  where
    timerFor parent review = do
      pending <- bounded timeout (Timer.findPendingTimers (Timer.PendingTimerFilter (Just approvalWorkflowName.unWorkflowName) (Just (reviewRequestIdText review))) (Timer.PendingTimerPageRequest 1 Nothing))
      pure case pending of
        Just (Right page) | page.next == Nothing -> case page.timers of
          [inspection]
            | validApprovalPayload inspection.timer.payload,
              inspection.timer.processManagerName == approvalWorkflowName.unWorkflowName,
              inspection.timer.correlationId == reviewRequestIdText review ->
                (Just (ApprovalObservation review parent (Just inspection.timer.fireAt) ApprovalPending page.observedAt), Nothing)
          [] -> (Just (ApprovalObservation review parent Nothing ApprovalNoTimer page.observedAt), Nothing)
          [_] -> (Nothing, Just parent)
          _ -> (Nothing, Just parent)
        _ -> (Nothing, Just parent)

bounded :: (WaitingEffects es) => Duration "watchdog-statement" -> Eff es a -> Eff es (Maybe a)
bounded duration action = do
  result <- tryError @StoreError (Timeout.runTimeout (Timeout.timeout (max 1 (min 2000000 (ceiling (durationTime duration * 1000000)))) (raise action)))
  pure (either (const Nothing) id result)

readHeader :: (WaitingEffects es) => Duration "watchdog-statement" -> WorkflowCoordinate -> Eff es WorkflowObservation
readHeader duration workflow = do
  observed <- bounded duration (Workflow.lookupInstance (WorkflowName workflow.name) (WorkflowId workflow.identifier))
  now <- liftIO getCurrentTime
  pure case observed of
    Nothing -> WorkflowObservation workflow Nothing HeaderUnavailable now
    Just Nothing -> WorkflowObservation workflow Nothing HeaderAbsent now
    Just (Just row) ->
      WorkflowObservation
        workflow
        (Just (fromIntegral row.generation))
        ( case row.status of
            Workflow.WfRunning -> HeaderRunning
            Workflow.WfSuspended -> HeaderSuspended
            Workflow.WfCompleted -> HeaderCompleted
            Workflow.WfCancelled -> HeaderCancelled
            Workflow.WfFailed -> HeaderFailed
        )
        now

validApprovalPayload :: Value -> Bool
validApprovalPayload (Object fields)
  | all (`elem` ["kind", "awakeableId"]) (KeyMap.keys fields),
    KeyMap.lookup "kind" fields == Just (String approvalTimeoutKind),
    Just token <- KeyMap.lookup "awakeableId" fields = case Aeson.fromJSON @AwakeableId token of Aeson.Success _ -> True; _ -> False
validApprovalPayload _ = False

instance ToJSON WorkflowCoordinate where
  toJSON value = object ["name" .= value.name, "identifier" .= value.identifier]

instance FromJSON WorkflowCoordinate where
  parseJSON = withObject "WorkflowCoordinate" \fields -> WorkflowCoordinate <$> fields .: "name" <*> fields .: "identifier"

instance ToJSON WorkflowObservation where
  toJSON value = object ["workflow" .= value.workflow, "generation" .= value.generation, "status" .= value.status, "observedAt" .= value.observedAt]

instance FromJSON WorkflowObservation where
  parseJSON = withObject "WorkflowObservation" \fields -> WorkflowObservation <$> fields .: "workflow" <*> fields .: "generation" <*> fields .: "status" <*> fields .: "observedAt"

instance ToJSON ApprovalObservation where
  toJSON value = object ["review" .= value.review, "parent" .= value.parent, "until" .= value.until, "phase" .= value.phase, "observedAt" .= value.observedAt]

instance FromJSON ApprovalObservation where
  parseJSON = withObject "ApprovalObservation" \fields -> ApprovalObservation <$> fields .: "review" <*> fields .: "parent" <*> fields .: "until" <*> fields .: "phase" <*> fields .: "observedAt"

instance ToJSON WaitingPage where
  toJSON value = object ["workflows" .= value.workflows, "approvals" .= value.approvals, "unknownParents" .= value.unknownParents]

instance FromJSON WaitingPage where
  parseJSON = withObject "WaitingPage" \fields -> WaitingPage <$> fields .: "workflows" <*> fields .: "approvals" <*> fields .: "unknownParents"

instance ToJSON HeaderStatus where
  toJSON =
    toJSON . \case
      HeaderRunning -> ("running" :: Text)
      HeaderSuspended -> ("suspended" :: Text)
      HeaderCompleted -> ("completed" :: Text)
      HeaderCancelled -> ("cancelled" :: Text)
      HeaderFailed -> ("failed" :: Text)
      HeaderAbsent -> ("absent" :: Text)
      HeaderUnavailable -> ("unavailable" :: Text)

instance FromJSON HeaderStatus where
  parseJSON = withText "HeaderStatus" \case
    "running" -> pure HeaderRunning
    "suspended" -> pure HeaderSuspended
    "completed" -> pure HeaderCompleted
    "cancelled" -> pure HeaderCancelled
    "failed" -> pure HeaderFailed
    "absent" -> pure HeaderAbsent
    "unavailable" -> pure HeaderUnavailable
    _ -> fail "unknown workflow header status"

instance ToJSON ApprovalPhase where
  toJSON =
    toJSON . \case
      ApprovalPending -> ("pending" :: Text)
      ApprovalNoTimer -> "no-timer"
      ApprovalTerminal -> "terminal"
      ApprovalParentInactive -> "parent-inactive"
      ApprovalUnavailable -> "unavailable"

instance FromJSON ApprovalPhase where
  parseJSON = withText "ApprovalPhase" \case
    "pending" -> pure ApprovalPending
    "no-timer" -> pure ApprovalNoTimer
    "terminal" -> pure ApprovalTerminal
    "parent-inactive" -> pure ApprovalParentInactive
    "unavailable" -> pure ApprovalUnavailable
    _ -> fail "unknown approval phase"
