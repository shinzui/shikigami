-- | Consumer contracts for authoritative workspace fencing and objective
-- ownership. These adapters do not supply the separately owned real providers.
module Shikigami.WorkerSession.Transfer where

import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.Prelude
import Shikigami.WorkerSession.Checkpoint (ObjectiveVersion (..))
import Shikigami.WorkerSession.Types (ObjectiveRef, WorkerSessionId)

data WorkspaceRef = WorkspaceRef {provider :: !Text, resource :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data TransferIntent = TransferIntent
  { format :: !Int,
    sessionId :: !WorkerSessionId,
    objective :: !ObjectiveRef,
    actor :: !AgentIdentity,
    operationId :: !OperationId,
    expected :: !ObjectiveVersion,
    oldOwner :: !AgentIdentity,
    newOwner :: !AgentIdentity,
    newWorker :: !AgentName,
    oldEpoch :: !Integer,
    newEpoch :: !Integer,
    rootId :: !ExecutionRootId,
    workspace :: !WorkspaceRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data FenceProof = FenceProof
  { format :: !Int,
    workspace :: !WorkspaceRef,
    operationId :: !OperationId,
    fingerprint :: !Text,
    oldEpoch :: !Integer,
    newEpoch :: !Integer,
    receipt :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data FenceOutcome = FencedAndSettled !FenceProof | FenceUnresolved | FenceConflict | FenceUnavailable
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data OwnershipReceipt = OwnershipReceipt
  { format :: !Int,
    objective :: !ObjectiveRef,
    operationId :: !OperationId,
    fingerprint :: !Text,
    revision :: !Integer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data OwnershipOutcome = OwnershipAccepted !OwnershipReceipt | OwnershipConflict | OwnershipUnresolved | OwnershipUnavailable
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data WorkspaceProvider = WorkspaceProvider
  { -- Must fence former writes before returning settled, including processes
    -- already executing. Expiry alone returns unresolved. The operation is
    -- deduplicated; retries reconcile rather than allocating a new workspace.
    reconcile :: TransferIntent -> IO FenceOutcome,
    -- Every real write requires both fresh current-session authority and a
    -- conditional provider epoch check at the effect boundary. A text epoch
    -- supplied by a model is not an authorization grant.
    admitWrite :: WorkspaceRef -> WorkerSessionId -> AgentIdentity -> Integer -> OperationId -> IO (Either Text ())
  }

newtype OwnershipProvider = OwnershipProvider
  { -- Deduplicate before checking expected versions. An accepted update must
    -- change the owner and epoch atomically, preserve accepted evidence and
    -- reject stale concurrent checkpoint updates that would restore an owner.
    transfer :: TransferIntent -> FenceProof -> IO OwnershipOutcome
  }

transferFingerprint :: TransferIntent -> Text
transferFingerprint intent = versionedDigest "shikigami.worker-session-transfer/1" (toJSON intent)

ownershipFingerprint :: TransferIntent -> FenceProof -> Text
ownershipFingerprint intent proof = versionedDigest "shikigami.worker-session-owner/1" (toJSON (intent, proof))

matchesFence :: TransferIntent -> FenceProof -> Bool
matchesFence intent proof =
  proof.format == 1
    && proof.workspace == intent.workspace
    && proof.operationId == intent.operationId
    && proof.fingerprint == transferFingerprint intent
    && proof.oldEpoch == intent.oldEpoch
    && proof.newEpoch == intent.newEpoch
    && proof.receipt /= ""

matchesOwnership :: TransferIntent -> FenceProof -> OwnershipReceipt -> Bool
matchesOwnership intent proof receipt =
  matchesFence intent proof
    && receipt.format == 1
    && receipt.objective == intent.objective
    && receipt.operationId == intent.operationId
    && receipt.fingerprint == ownershipFingerprint intent proof
    && receipt.revision > intent.expected.revision
