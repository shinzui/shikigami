-- | Protected allocation metadata. These values are not workflow journal input
-- and confer no read, mutation, process or transfer authority.
module Shikigami.Workspace.Types where

import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Prelude
import Shikigami.WorkerSession.Transfer (WorkspaceRef)
import Shikigami.WorkerSession.Types (AssignmentId, WorkerSessionId)

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
