-- Hand-owned canonical histories and commands for every checked lifecycle cell.
module Shikigami.ExecutionLifecycle.BehaviorHoles (behaviorWitnesses) where

import Shikigami.ExecutionLifecycle.Generated.BehaviorContract
import Shikigami.ExecutionLifecycle.Generated.Domain
import Shikigami.Prelude

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses = map witness behaviorRequirements

witness :: BehaviorRequirement -> BehaviorWitness
witness requirement =
  LiveWitness
    { key = requirement.key,
      history = historyFor requirement.source,
      command = commandFor requirement.source requirement.commandName,
      expected = case requirement.kind of
        LiveTransition -> Emits (eventFor requirement.source requirement.commandName :| [])
        RequiredRejection -> Rejects (if requirement.source `elem` [ExecutionLifecycleSucceeded, ExecutionLifecycleFailed, ExecutionLifecycleCancelled] then RejectNoOutgoingEdges else RejectNoMatchingEdge)
        ReplayTransition -> error "ExecutionLifecycle has no replay-only transition"
    }

historyFor :: ExecutionLifecycleVertex -> [ExecutionLifecycleEvent]
historyFor source = case source of
  ExecutionLifecycleMissing -> []
  ExecutionLifecycleActive -> [admitted]
  ExecutionLifecycleParked -> [admitted, eventFor ExecutionLifecycleActive "ParkExecution"]
  ExecutionLifecycleUnresolved -> [admitted, eventFor ExecutionLifecycleActive "MarkExecutionUnresolved"]
  ExecutionLifecycleSucceeded -> [admitted, eventFor ExecutionLifecycleActive "FinishExecution"]
  ExecutionLifecycleFailed -> [admitted, eventFor ExecutionLifecycleActive "FailExecution"]
  ExecutionLifecycleCancelled -> [admitted, eventFor ExecutionLifecycleActive "CancelExecution"]

revisionFor :: ExecutionLifecycleVertex -> Int
revisionFor source = if source `elem` [ExecutionLifecycleMissing, ExecutionLifecycleActive] then 0 else 1

commandFor :: ExecutionLifecycleVertex -> Text -> ExecutionLifecycleCommand
commandFor source name =
  let r = revisionFor source
   in case name of
        "AdmitExecution" -> AdmitExecution (AdmitExecutionData "fixture-execution" "fixture-snapshot")
        "AdvanceExecution" -> AdvanceExecution (AdvanceExecutionData "fixture-execution" r (r + 1))
        "ParkExecution" -> ParkExecution (ParkExecutionData "fixture-execution" r (r + 1))
        "ResumeExecution" -> ResumeExecution (ResumeExecutionData "fixture-execution" r (r + 1))
        "MarkExecutionUnresolved" -> MarkExecutionUnresolved (MarkExecutionUnresolvedData "fixture-execution" r (r + 1))
        "ReconcileExecution" -> ReconcileExecution (ReconcileExecutionData "fixture-execution" r (r + 1))
        "FinishExecution" -> FinishExecution (FinishExecutionData "fixture-execution" r (r + 1))
        "FailExecution" -> FailExecution (FailExecutionData "fixture-execution" r (r + 1))
        "CancelExecution" -> CancelExecution (CancelExecutionData "fixture-execution" r (r + 1))
        _ -> error "unknown checked execution command"

eventFor :: ExecutionLifecycleVertex -> Text -> ExecutionLifecycleEvent
eventFor source name =
  let r = revisionFor source
   in case name of
        "AdmitExecution" -> admitted
        "AdvanceExecution" -> ExecutionAdvanced (ExecutionAdvancedData "fixture-execution" r (r + 1))
        "ParkExecution" -> ExecutionParked (ExecutionParkedData "fixture-execution" r (r + 1))
        "ResumeExecution" -> ExecutionResumed (ExecutionResumedData "fixture-execution" r (r + 1))
        "MarkExecutionUnresolved" -> ExecutionBecameUnresolved (ExecutionBecameUnresolvedData "fixture-execution" r (r + 1))
        "ReconcileExecution" -> ExecutionReconciled (ExecutionReconciledData "fixture-execution" r (r + 1))
        "FinishExecution" -> ExecutionFinished (ExecutionFinishedData "fixture-execution" r (r + 1))
        "FailExecution" -> ExecutionFailed (ExecutionFailedData "fixture-execution" r (r + 1))
        "CancelExecution" -> ExecutionCancelled (ExecutionCancelledData "fixture-execution" r (r + 1))
        _ -> error "unknown checked execution event"

admitted :: ExecutionLifecycleEvent
admitted = ExecutionAdmitted (ExecutionAdmittedData "fixture-execution" "fixture-snapshot")
