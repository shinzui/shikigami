-- | Consumer contract for the separately owned objective/checkpoint provider.
-- No production provider is selected by this module. A provider must deduplicate
-- an operation before checking its expected revision, including after a lost
-- acknowledgement, and atomically reject stale owner/revision updates.
module Shikigami.WorkerSession.Checkpoint where

import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.Prelude
import Shikigami.WorkerSession.Types (EventReceipt, ObjectiveRef, WorkerSessionId)

data ObjectiveVersion = ObjectiveVersion
  { revision :: !Integer,
    assignmentRevision :: !Integer,
    criteriaRevision :: !Integer,
    ownerEpoch :: !Integer,
    owner :: !AgentIdentity,
    active :: !Bool,
    rootId :: !ExecutionRootId,
    cutoff :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CheckpointIntent = CheckpointIntent
  { format :: !Int,
    sessionId :: !WorkerSessionId,
    objective :: !ObjectiveRef,
    operationId :: !OperationId,
    actor :: !AgentIdentity,
    epoch :: !Integer,
    expected :: !ObjectiveVersion,
    previousCursor :: !Integer,
    throughCursor :: !Integer,
    events :: ![EventReceipt]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CheckpointReceipt = CheckpointReceipt
  { format :: !Int,
    objective :: !ObjectiveRef,
    operationId :: !OperationId,
    fingerprint :: !Text,
    revision :: !Integer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CheckpointOutcome = CheckpointAccepted !CheckpointReceipt | CheckpointConflict | CheckpointUnresolved | CheckpointUnavailable
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CheckpointProvider = CheckpointProvider
  { current :: ObjectiveRef -> IO (Either Text ObjectiveVersion),
    commit :: CheckpointIntent -> IO CheckpointOutcome
  }

intentFingerprint :: CheckpointIntent -> Text
intentFingerprint intent = versionedDigest "shikigami.worker-session-checkpoint/1" (toJSON intent)

matchesReceipt :: CheckpointIntent -> CheckpointReceipt -> Bool
matchesReceipt intent receipt =
  receipt.format == 1
    && receipt.objective == intent.objective
    && receipt.operationId == intent.operationId
    && receipt.fingerprint == intentFingerprint intent
    && receipt.revision > intent.expected.revision
