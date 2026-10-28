-- Hand-owned canonical histories and commands for every checked lifecycle cell.
module Shikigami.ExecutionLifecycle.BehaviorHoles (behaviorWitnesses) where

import Shikigami.ExecutionLifecycle.Generated.BehaviorContract
import Shikigami.ExecutionLifecycle.Generated.Domain
import Shikigami.Prelude

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses = map witness behaviorRequirements

witness :: BehaviorRequirement -> BehaviorWitness
witness requirement =
  let history = historyFor requirement
      revision = max 0 (length history - 1)
      remaining = if requirement.target `elem` map Just pendingStates then 1 else 0
   in LiveWitness
        { key = requirement.key,
          history,
          command = commandFor requirement.commandName revision remaining,
          expected = case requirement.kind of
            LiveTransition -> Emits (eventFor requirement.commandName revision remaining (requirement.source `elem` pendingStates && remaining == 0) :| [])
            RequiredRejection -> Rejects (if requirement.source `elem` [ExecutionLifecycleSucceeded, ExecutionLifecycleFailed, ExecutionLifecycleCancelled] then RejectNoOutgoingEdges else RejectNoMatchingEdge)
            ReplayTransition -> error "ExecutionLifecycle has no replay-only transition"
        }

pendingStates :: [ExecutionLifecycleVertex]
pendingStates = [ExecutionLifecycleSucceededPendingReceipts, ExecutionLifecycleFailedPendingReceipts, ExecutionLifecycleCancelledPendingReceipts]

historyFor :: BehaviorRequirement -> [ExecutionLifecycleEvent]
historyFor requirement =
  let prefix = retries (if requirement.source `elem` pendingStates && requirement.target `elem` map Just pendingStates then 2 else 1)
      r = length prefix - 1
      pending source = prefix <> [eventFor source r 0 False]
   in case requirement.source of
        ExecutionLifecycleMissing -> []
        ExecutionLifecycleActive | requirement.commandName `elem` ["SettleExecutionReceipt", "FinishExecutionPendingReceipts", "FailExecutionPendingReceipts", "CancelExecutionPendingReceipts"] -> prefix
        ExecutionLifecycleActive -> [admitted]
        ExecutionLifecycleParked | requirement.commandName `elem` ["SettleExecutionReceipt", "FailExecutionPendingReceipts", "CancelExecutionPendingReceipts"] -> pending "ParkExecution"
        ExecutionLifecycleParked -> [admitted, eventFor "ParkExecution" 0 0 False]
        ExecutionLifecycleUnresolved | requirement.commandName `elem` ["SettleExecutionReceipt", "FailExecutionPendingReceipts", "CancelExecutionPendingReceipts"] -> pending "MarkExecutionUnresolved"
        ExecutionLifecycleUnresolved -> [admitted, eventFor "MarkExecutionUnresolved" 0 0 False]
        ExecutionLifecycleSucceededPendingReceipts -> pending "FinishExecutionPendingReceipts"
        ExecutionLifecycleFailedPendingReceipts -> pending "FailExecutionPendingReceipts"
        ExecutionLifecycleCancelledPendingReceipts -> pending "CancelExecutionPendingReceipts"
        ExecutionLifecycleSucceeded -> [admitted, eventFor "FinishExecution" 0 0 False]
        ExecutionLifecycleFailed -> [admitted, eventFor "FailExecution" 0 0 False]
        ExecutionLifecycleCancelled -> [admitted, eventFor "CancelExecution" 0 0 False]
  where
    retries count = foldl' (\history _ -> let r = length history - 1 in history <> [eventFor "MarkExecutionUnresolved" r 0 False, eventFor "RetryExecution" (r + 1) 0 False]) [admitted] [1 .. count]

commandFor :: Text -> Int -> Integer -> ExecutionLifecycleCommand
commandFor name r remaining = case name of
  "AdmitExecution" -> AdmitExecution (AdmitExecutionData "fixture-execution" "fixture-snapshot")
  "AdvanceExecution" -> AdvanceExecution (AdvanceExecutionData "fixture-execution" r (r + 1))
  "ParkExecution" -> ParkExecution (ParkExecutionData "fixture-execution" r (r + 1))
  "ResumeExecution" -> ResumeExecution (ResumeExecutionData "fixture-execution" r (r + 1))
  "MarkExecutionUnresolved" -> MarkExecutionUnresolved (MarkExecutionUnresolvedData "fixture-execution" r (r + 1))
  "ReconcileExecution" -> ReconcileExecution (ReconcileExecutionData "fixture-execution" r (r + 1))
  "FinishExecution" -> FinishExecution (FinishExecutionData "fixture-execution" r (r + 1))
  "FailExecution" -> FailExecution (FailExecutionData "fixture-execution" r (r + 1))
  "CancelExecution" -> CancelExecution (CancelExecutionData "fixture-execution" r (r + 1))
  "RetryExecution" -> RetryExecution (RetryExecutionData "fixture-execution" r (r + 1))
  "SettleExecutionReceipt" -> SettleExecutionReceipt (SettleExecutionReceiptData "fixture-execution" r (r + 1) remaining)
  "FinishExecutionPendingReceipts" -> FinishExecutionPendingReceipts (FinishExecutionPendingReceiptsData "fixture-execution" r (r + 1))
  "FailExecutionPendingReceipts" -> FailExecutionPendingReceipts (FailExecutionPendingReceiptsData "fixture-execution" r (r + 1))
  "CancelExecutionPendingReceipts" -> CancelExecutionPendingReceipts (CancelExecutionPendingReceiptsData "fixture-execution" r (r + 1))
  _ -> error "unknown checked execution command"

eventFor :: Text -> Int -> Integer -> Bool -> ExecutionLifecycleEvent
eventFor name r remaining closed = case name of
  "AdmitExecution" -> admitted
  "AdvanceExecution" -> ExecutionAdvanced (ExecutionAdvancedData "fixture-execution" r (r + 1))
  "ParkExecution" -> ExecutionParked (ExecutionParkedData "fixture-execution" r (r + 1))
  "ResumeExecution" -> ExecutionResumed (ExecutionResumedData "fixture-execution" r (r + 1))
  "MarkExecutionUnresolved" -> ExecutionBecameUnresolved (ExecutionBecameUnresolvedData "fixture-execution" r (r + 1))
  "ReconcileExecution" -> ExecutionReconciled (ExecutionReconciledData "fixture-execution" r (r + 1))
  "FinishExecution" -> ExecutionFinished (ExecutionFinishedData "fixture-execution" r (r + 1))
  "FailExecution" -> ExecutionFailed (ExecutionFailedData "fixture-execution" r (r + 1))
  "CancelExecution" -> ExecutionCancelled (ExecutionCancelledData "fixture-execution" r (r + 1))
  "RetryExecution" -> ExecutionRetried (ExecutionRetriedData "fixture-execution" r (r + 1))
  "SettleExecutionReceipt" | closed -> ExecutionReceiptsClosed (ExecutionReceiptsClosedData "fixture-execution" r (r + 1) remaining)
  "SettleExecutionReceipt" -> ExecutionReceiptSettled (ExecutionReceiptSettledData "fixture-execution" r (r + 1) remaining)
  "FinishExecutionPendingReceipts" -> ExecutionFinishedPendingReceipts (ExecutionFinishedPendingReceiptsData "fixture-execution" r (r + 1))
  "FailExecutionPendingReceipts" -> ExecutionFailedPendingReceipts (ExecutionFailedPendingReceiptsData "fixture-execution" r (r + 1))
  "CancelExecutionPendingReceipts" -> ExecutionCancelledPendingReceipts (ExecutionCancelledPendingReceiptsData "fixture-execution" r (r + 1))
  _ -> error "unknown checked execution event"

admitted :: ExecutionLifecycleEvent
admitted = ExecutionAdmitted (ExecutionAdmittedData "fixture-execution" "fixture-snapshot")
