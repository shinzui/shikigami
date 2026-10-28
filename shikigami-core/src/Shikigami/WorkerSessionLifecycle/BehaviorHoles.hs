-- Hand-owned histories exercise every checked lifecycle cell.
module Shikigami.WorkerSessionLifecycle.BehaviorHoles (behaviorWitnesses) where

import Shikigami.Prelude
import Shikigami.WorkerSessionLifecycle.Generated.BehaviorContract
import Shikigami.WorkerSessionLifecycle.Generated.Domain

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses = map witness behaviorRequirements

witness :: BehaviorRequirement -> BehaviorWitness
witness requirement =
  let history = historyFor requirement.source
      revision = max 0 (length history - 1)
   in LiveWitness
        { key = requirement.key,
          history,
          command = commandFor requirement.commandName revision,
          expected = case requirement.kind of
            LiveTransition -> Emits (eventFor requirement.commandName revision :| [])
            RequiredRejection -> Rejects RejectNoMatchingEdge
            ReplayTransition -> error "worker session has no replay-only transition"
        }

historyFor :: WorkerSessionLifecycleVertex -> [WorkerSessionLifecycleEvent]
historyFor source = case source of
  WorkerSessionLifecycleMissing -> []
  WorkerSessionLifecycleIdle -> [admitted]
  WorkerSessionLifecycleActive -> [admitted, eventFor "StartSessionAssignment" 0]
  WorkerSessionLifecycleParked -> [admitted, eventFor "StartSessionAssignment" 0, eventFor "ParkSessionAssignment" 1]
  WorkerSessionLifecycleUnresolved -> [admitted, eventFor "StartSessionAssignment" 0, eventFor "MarkSessionUnresolved" 1]
  WorkerSessionLifecycleTransferring -> [admitted, eventFor "RequestSessionTransfer" 0]
  WorkerSessionLifecycleFailed -> [admitted, eventFor "FailWorkerSession" 0]
  WorkerSessionLifecycleCancelled -> [admitted, eventFor "CancelWorkerSession" 0]

commandFor :: Text -> Int -> WorkerSessionLifecycleCommand
commandFor name revision = case name of
  "AdmitWorkerSession" -> AdmitWorkerSession (AdmitWorkerSessionData "fixture-session" "fixture-binding")
  "AcceptSessionMessage" -> AcceptSessionMessage (AcceptSessionMessageData "fixture-session" revision (revision + 1))
  "StartSessionAssignment" -> StartSessionAssignment (StartSessionAssignmentData "fixture-session" revision (revision + 1))
  "ParkSessionAssignment" -> ParkSessionAssignment (ParkSessionAssignmentData "fixture-session" revision (revision + 1))
  "ResumeSessionAssignment" -> ResumeSessionAssignment (ResumeSessionAssignmentData "fixture-session" revision (revision + 1))
  "RecordSessionResult" -> RecordSessionResult (RecordSessionResultData "fixture-session" revision (revision + 1))
  "MarkSessionUnresolved" -> MarkSessionUnresolved (MarkSessionUnresolvedData "fixture-session" revision (revision + 1))
  "ReconcileSessionAssignment" -> ReconcileSessionAssignment (ReconcileSessionAssignmentData "fixture-session" revision (revision + 1))
  "RequestSessionTransfer" -> RequestSessionTransfer (RequestSessionTransferData "fixture-session" revision (revision + 1))
  "ReconcileSessionTransfer" -> ReconcileSessionTransfer (ReconcileSessionTransferData "fixture-session" revision (revision + 1))
  "EstablishSessionOwner" -> EstablishSessionOwner (EstablishSessionOwnerData "fixture-session" revision (revision + 1))
  "ObserveWorkerSession" -> ObserveWorkerSession (ObserveWorkerSessionData "fixture-session" revision (revision + 1))
  "PrepareSessionCheckpoint" -> PrepareSessionCheckpoint (PrepareSessionCheckpointData "fixture-session" revision (revision + 1))
  "ConsumeSessionEvents" -> ConsumeSessionEvents (ConsumeSessionEventsData "fixture-session" revision (revision + 1))
  "FailWorkerSession" -> FailWorkerSession (FailWorkerSessionData "fixture-session" revision (revision + 1))
  "CancelWorkerSession" -> CancelWorkerSession (CancelWorkerSessionData "fixture-session" revision (revision + 1))
  _ -> error "unknown worker session command"

eventFor :: Text -> Int -> WorkerSessionLifecycleEvent
eventFor name revision = case name of
  "AdmitWorkerSession" -> WorkerSessionAdmitted (WorkerSessionAdmittedData "fixture-session" "fixture-binding")
  "AcceptSessionMessage" -> SessionMessageAccepted (SessionMessageAcceptedData "fixture-session" revision (revision + 1))
  "StartSessionAssignment" -> SessionAssignmentStarted (SessionAssignmentStartedData "fixture-session" revision (revision + 1))
  "ParkSessionAssignment" -> SessionAssignmentParked (SessionAssignmentParkedData "fixture-session" revision (revision + 1))
  "ResumeSessionAssignment" -> SessionAssignmentResumed (SessionAssignmentResumedData "fixture-session" revision (revision + 1))
  "RecordSessionResult" -> SessionResultRecorded (SessionResultRecordedData "fixture-session" revision (revision + 1))
  "MarkSessionUnresolved" -> SessionBecameUnresolved (SessionBecameUnresolvedData "fixture-session" revision (revision + 1))
  "ReconcileSessionAssignment" -> SessionAssignmentReconciled (SessionAssignmentReconciledData "fixture-session" revision (revision + 1))
  "RequestSessionTransfer" -> SessionTransferRequested (SessionTransferRequestedData "fixture-session" revision (revision + 1))
  "ReconcileSessionTransfer" -> SessionTransferReconciled (SessionTransferReconciledData "fixture-session" revision (revision + 1))
  "EstablishSessionOwner" -> SessionOwnerEstablished (SessionOwnerEstablishedData "fixture-session" revision (revision + 1))
  "ObserveWorkerSession" -> WorkerSessionObserved (WorkerSessionObservedData "fixture-session" revision (revision + 1))
  "PrepareSessionCheckpoint" -> SessionCheckpointPrepared (SessionCheckpointPreparedData "fixture-session" revision (revision + 1))
  "ConsumeSessionEvents" -> SessionEventsConsumed (SessionEventsConsumedData "fixture-session" revision (revision + 1))
  "FailWorkerSession" -> WorkerSessionFailed (WorkerSessionFailedData "fixture-session" revision (revision + 1))
  "CancelWorkerSession" -> WorkerSessionCancelled (WorkerSessionCancelledData "fixture-session" revision (revision + 1))
  _ -> error "unknown worker session event"

admitted :: WorkerSessionLifecycleEvent
admitted = eventFor "AdmitWorkerSession" 0
