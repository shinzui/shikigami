-- | Protected allocation metadata. These values are not workflow journal input
-- and confer no read, mutation, process or transfer authority.
module Shikigami.Workspace.Types where

import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Prelude
import Shikigami.WorkerSession.Transfer (WorkspaceRef)
import Shikigami.WorkerSession.Types (AssignmentId, WorkerSessionId)
import Shikigami.Workspace.Instructions (WorkspaceAdmission (..), bundleBase, bundleRepository, transferableFilePolicy)

data WorkspaceRequest = WorkspaceRequest
  { runId :: !Text,
    assignment :: !(Maybe (WorkerSessionId, AssignmentId)),
    rootId :: !ExecutionRootId,
    principal :: !AgentIdentity,
    owner :: !AgentIdentity,
    epoch :: !Integer
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show WorkspaceRequest where show _ = "WorkspaceRequest <protected>"

data WorkspaceBinding = WorkspaceBinding
  { request :: !WorkspaceRequest,
    workspace :: !WorkspaceRef,
    repository :: !Text,
    base :: !Text,
    policyRevision :: !Text,
    storageRoot :: !FilePath,
    source :: !FilePath
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show WorkspaceBinding where show _ = "WorkspaceBinding <protected>"

data AllocationState = Reserved | Ready
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data WorkspaceError = InvalidWorkspaceRequest | WorkspaceBindingConflict | WorkspaceMissing | WorkspaceAllocationRefused
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Protected snapshot correlation, distinct from an allocation completion marker.
workspaceBindingDigest :: WorkspaceBinding -> Text
workspaceBindingDigest = versionedDigest "shikigami.workspace-binding/1" . toJSON

-- Pure shape only. Successor authority additionally requires its exact retained
-- admission and current session/owner checks in TransferStore at the IO boundary.
matchesWorkspaceAdmission :: WorkspaceBinding -> WorkspaceAdmission -> Bool
matchesWorkspaceAdmission binding admission =
  admission.workspace == binding.workspace
    && admission.bindingDigest == workspaceBindingDigest binding
    && admission.rootId == binding.request.rootId
    && bundleRepository admission.instructions == binding.repository
    && bundleBase admission.instructions == binding.base
    && ( (admission.runId == binding.request.runId && admission.owner == binding.request.owner && admission.epoch == binding.request.epoch)
           || (admission.filePolicy == Just transferableFilePolicy && admission.epoch > binding.request.epoch && admission.epoch < 9223372036854775808 && admission.runId /= binding.request.runId && admission.runId /= "" && admission.assignmentId /= "")
       )
