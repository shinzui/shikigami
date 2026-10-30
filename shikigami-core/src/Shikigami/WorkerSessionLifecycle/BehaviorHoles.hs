-- Hand-owned histories exercise every checked lifecycle cell.
module Shikigami.WorkerSessionLifecycle.BehaviorHoles (behaviorWitnesses) where

import Shikigami.Prelude
import Shikigami.WorkerSession.Types (WorkerSessionId (..))
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
  "AdmitWorkerSession" -> AdmitWorkerSession (AdmitWorkerSessionData (WorkerSessionId "fixture-session") "fixture-binding")
  "AcceptSessionMessage" -> AcceptSessionMessage (AcceptSessionMessageData (WorkerSessionId "fixture-session") revision (revision + 1))
  "StartSessionAssignment" -> StartSessionAssignment (StartSessionAssignmentData (WorkerSessionId "fixture-session") revision (revision + 1))
  "ParkSessionAssignment" -> ParkSessionAssignment (ParkSessionAssignmentData (WorkerSessionId "fixture-session") revision (revision + 1))
  "ResumeSessionAssignment" -> ResumeSessionAssignment (ResumeSessionAssignmentData (WorkerSessionId "fixture-session") revision (revision + 1))
  "RecordSessionResult" -> RecordSessionResult (RecordSessionResultData (WorkerSessionId "fixture-session") revision (revision + 1))
  "MarkSessionUnresolved" -> MarkSessionUnresolved (MarkSessionUnresolvedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "ReconcileSessionAssignment" -> ReconcileSessionAssignment (ReconcileSessionAssignmentData (WorkerSessionId "fixture-session") revision (revision + 1))
  "RequestSessionTransfer" -> RequestSessionTransfer (RequestSessionTransferData (WorkerSessionId "fixture-session") revision (revision + 1))
  "ReconcileSessionTransfer" -> ReconcileSessionTransfer (ReconcileSessionTransferData (WorkerSessionId "fixture-session") revision (revision + 1))
  "EstablishSessionOwner" -> EstablishSessionOwner (EstablishSessionOwnerData (WorkerSessionId "fixture-session") revision (revision + 1))
  "SubscribeSessionEvents" -> SubscribeSessionEvents (SubscribeSessionEventsData (WorkerSessionId "fixture-session") revision (revision + 1))
  "ObserveWorkerSession" -> ObserveWorkerSession (ObserveWorkerSessionData (WorkerSessionId "fixture-session") revision (revision + 1))
  "PrepareSessionCheckpoint" -> PrepareSessionCheckpoint (PrepareSessionCheckpointData (WorkerSessionId "fixture-session") revision (revision + 1))
  "ConsumeSessionEvents" -> ConsumeSessionEvents (ConsumeSessionEventsData (WorkerSessionId "fixture-session") revision (revision + 1))
  "FailWorkerSession" -> FailWorkerSession (FailWorkerSessionData (WorkerSessionId "fixture-session") revision (revision + 1))
  "CancelWorkerSession" -> CancelWorkerSession (CancelWorkerSessionData (WorkerSessionId "fixture-session") revision (revision + 1))
  _ -> error "unknown worker session command"

eventFor :: Text -> Int -> WorkerSessionLifecycleEvent
eventFor name revision = case name of
  "AdmitWorkerSession" -> WorkerSessionAdmitted (WorkerSessionAdmittedData (WorkerSessionId "fixture-session") "fixture-binding")
  "AcceptSessionMessage" -> SessionMessageAccepted (SessionMessageAcceptedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "StartSessionAssignment" -> SessionAssignmentStarted (SessionAssignmentStartedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "ParkSessionAssignment" -> SessionAssignmentParked (SessionAssignmentParkedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "ResumeSessionAssignment" -> SessionAssignmentResumed (SessionAssignmentResumedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "RecordSessionResult" -> SessionResultRecorded (SessionResultRecordedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "MarkSessionUnresolved" -> SessionBecameUnresolved (SessionBecameUnresolvedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "ReconcileSessionAssignment" -> SessionAssignmentReconciled (SessionAssignmentReconciledData (WorkerSessionId "fixture-session") revision (revision + 1))
  "RequestSessionTransfer" -> SessionTransferRequested (SessionTransferRequestedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "ReconcileSessionTransfer" -> SessionTransferReconciled (SessionTransferReconciledData (WorkerSessionId "fixture-session") revision (revision + 1))
  "EstablishSessionOwner" -> SessionOwnerEstablished (SessionOwnerEstablishedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "SubscribeSessionEvents" -> SessionEventsSubscribed (SessionEventsSubscribedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "ObserveWorkerSession" -> WorkerSessionObserved (WorkerSessionObservedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "PrepareSessionCheckpoint" -> SessionCheckpointPrepared (SessionCheckpointPreparedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "ConsumeSessionEvents" -> SessionEventsConsumed (SessionEventsConsumedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "FailWorkerSession" -> WorkerSessionFailed (WorkerSessionFailedData (WorkerSessionId "fixture-session") revision (revision + 1))
  "CancelWorkerSession" -> WorkerSessionCancelled (WorkerSessionCancelledData (WorkerSessionId "fixture-session") revision (revision + 1))
  _ -> error "unknown worker session event"

admitted :: WorkerSessionLifecycleEvent
admitted = eventFor "AdmitWorkerSession" 0
