-- | Process-local workspace composition. Only the admitted protected snapshot
-- crosses a durable boundary; installation and repository selection are trusted
-- operator code, never model arguments.
module Shikigami.Workspace.Admission (WorkspaceHost (..)) where

import GHC.Generics (Generic)
import Shikigami.Capability.Provider (CapabilityRuntime)
import Shikigami.Execution.Start (SkillAssignment)
import Shikigami.Execution.Transcript (ExecutionError)
import Shikigami.Workspace.Instructions (WorkspaceAdmission)

data WorkspaceHost = WorkspaceHost
  { capabilities :: !CapabilityRuntime,
    load :: !(SkillAssignment -> IO (Either ExecutionError WorkspaceAdmission))
  }
  deriving stock (Generic)
