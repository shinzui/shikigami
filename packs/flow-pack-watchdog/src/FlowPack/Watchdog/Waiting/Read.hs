{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}

-- | Separately bounded public Keiro reads. Only an exact approval-owner link
-- permits a timer lookup: generic timer or child-result scans are forbidden.
module FlowPack.Watchdog.Waiting.Read (observeWaiting) where

import Control.Monad (forM)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, withText, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (nub)
import Data.Maybe (catMaybes)
import Data.Time (UTCTime, getCurrentTime)
import Effectful (Eff, IOE, liftIO, raise, (:>))
import Effectful.Error.Static (Error, tryError)
import Effectful.Timeout qualified as Timeout
import FlowPack.Watchdog.Waiting
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
