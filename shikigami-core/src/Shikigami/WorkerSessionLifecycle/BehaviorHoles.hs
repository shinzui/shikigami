-- Hand-owned histories exercise every checked lifecycle cell.
module Shikigami.WorkerSessionLifecycle.BehaviorHoles (behaviorWitnesses) where

import Shikigami.Prelude
import Shikigami.WorkerSession.Types (WorkerSessionId (value), workerSessionId)
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
  "AdmitWorkerSession" -> AdmitWorkerSession (AdmitWorkerSessionData (workerSessionId "fixture-session") "fixture-binding")
  "AcceptSessionMessage" -> AcceptSessionMessage (AcceptSessionMessageData (workerSessionId "fixture-session") revision (revision + 1))
  "StartSessionAssignment" -> StartSessionAssignment (StartSessionAssignmentData (workerSessionId "fixture-session") revision (revision + 1))
  "ParkSessionAssignment" -> ParkSessionAssignment (ParkSessionAssignmentData (workerSessionId "fixture-session") revision (revision + 1))
  "ResumeSessionAssignment" -> ResumeSessionAssignment (ResumeSessionAssignmentData (workerSessionId "fixture-session") revision (revision + 1))
  "RecordSessionResult" -> RecordSessionResult (RecordSessionResultData (workerSessionId "fixture-session") revision (revision + 1))
  "MarkSessionUnresolved" -> MarkSessionUnresolved (MarkSessionUnresolvedData (workerSessionId "fixture-session") revision (revision + 1))
  "ReconcileSessionAssignment" -> ReconcileSessionAssignment (ReconcileSessionAssignmentData (workerSessionId "fixture-session") revision (revision + 1))
  "RequestSessionTransfer" -> RequestSessionTransfer (RequestSessionTransferData (workerSessionId "fixture-session") revision (revision + 1))
  "ReconcileSessionTransfer" -> ReconcileSessionTransfer (ReconcileSessionTransferData (workerSessionId "fixture-session") revision (revision + 1))
  "EstablishSessionOwner" -> EstablishSessionOwner (EstablishSessionOwnerData (workerSessionId "fixture-session") revision (revision + 1))
  "SubscribeSessionEvents" -> SubscribeSessionEvents (SubscribeSessionEventsData (workerSessionId "fixture-session") revision (revision + 1))
  "ObserveWorkerSession" -> ObserveWorkerSession (ObserveWorkerSessionData (workerSessionId "fixture-session") revision (revision + 1))
  "PrepareSessionCheckpoint" -> PrepareSessionCheckpoint (PrepareSessionCheckpointData (workerSessionId "fixture-session") revision (revision + 1))
  "ConsumeSessionEvents" -> ConsumeSessionEvents (ConsumeSessionEventsData (workerSessionId "fixture-session") revision (revision + 1))
  "FailWorkerSession" -> FailWorkerSession (FailWorkerSessionData (workerSessionId "fixture-session") revision (revision + 1))
  "CancelWorkerSession" -> CancelWorkerSession (CancelWorkerSessionData (workerSessionId "fixture-session") revision (revision + 1))
  _ -> error "unknown worker session command"

eventFor :: Text -> Int -> WorkerSessionLifecycleEvent
eventFor name revision = case name of
  "AdmitWorkerSession" -> WorkerSessionAdmitted (WorkerSessionAdmittedData (workerSessionId "fixture-session") "fixture-binding")
  "AcceptSessionMessage" -> SessionMessageAccepted (SessionMessageAcceptedData (workerSessionId "fixture-session") revision (revision + 1))
  "StartSessionAssignment" -> SessionAssignmentStarted (SessionAssignmentStartedData (workerSessionId "fixture-session") revision (revision + 1))
  "ParkSessionAssignment" -> SessionAssignmentParked (SessionAssignmentParkedData (workerSessionId "fixture-session") revision (revision + 1))
  "ResumeSessionAssignment" -> SessionAssignmentResumed (SessionAssignmentResumedData (workerSessionId "fixture-session") revision (revision + 1))
  "RecordSessionResult" -> SessionResultRecorded (SessionResultRecordedData (workerSessionId "fixture-session") revision (revision + 1))
  "MarkSessionUnresolved" -> SessionBecameUnresolved (SessionBecameUnresolvedData (workerSessionId "fixture-session") revision (revision + 1))
  "ReconcileSessionAssignment" -> SessionAssignmentReconciled (SessionAssignmentReconciledData (workerSessionId "fixture-session") revision (revision + 1))
  "RequestSessionTransfer" -> SessionTransferRequested (SessionTransferRequestedData (workerSessionId "fixture-session") revision (revision + 1))
  "ReconcileSessionTransfer" -> SessionTransferReconciled (SessionTransferReconciledData (workerSessionId "fixture-session") revision (revision + 1))
  "EstablishSessionOwner" -> SessionOwnerEstablished (SessionOwnerEstablishedData (workerSessionId "fixture-session") revision (revision + 1))
  "SubscribeSessionEvents" -> SessionEventsSubscribed (SessionEventsSubscribedData (workerSessionId "fixture-session") revision (revision + 1))
  "ObserveWorkerSession" -> WorkerSessionObserved (WorkerSessionObservedData (workerSessionId "fixture-session") revision (revision + 1))
  "PrepareSessionCheckpoint" -> SessionCheckpointPrepared (SessionCheckpointPreparedData (workerSessionId "fixture-session") revision (revision + 1))
  "ConsumeSessionEvents" -> SessionEventsConsumed (SessionEventsConsumedData (workerSessionId "fixture-session") revision (revision + 1))
  "FailWorkerSession" -> WorkerSessionFailed (WorkerSessionFailedData (workerSessionId "fixture-session") revision (revision + 1))
  "CancelWorkerSession" -> WorkerSessionCancelled (WorkerSessionCancelledData (workerSessionId "fixture-session") revision (revision + 1))
  _ -> error "unknown worker session event"

admitted :: WorkerSessionLifecycleEvent
admitted = eventFor "AdmitWorkerSession" 0
