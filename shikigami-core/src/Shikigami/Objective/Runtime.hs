-- | Objective-owned composition for worker services. Missing workspace fencing
-- stays unavailable; accepted checkpoint readers remain installed when disabled.
module Shikigami.Objective.Runtime (coordinationHost) where

import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.Agent.Decl (AgentDecl, DelegationBudget)
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Directory qualified as Directory
import Shikigami.Objective.Checkpoint (checkpointProvider, checkpointRejection)
import Shikigami.Objective.Coordination (coordinationAuthority, objectiveHost)
import Shikigami.Objective.Ownership (ownershipProvider)
import Shikigami.Objective.Types (ObjectiveSettings)
import Shikigami.Prelude
import Shikigami.WorkerSession.Capability qualified as Worker
import Shikigami.WorkerSession.Handoff (TransferServices (..))
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Transfer qualified as Transfer
import Shikigami.WorkerSession.Types (SessionBinding (..))
import Shikigami.WorkerSession.Workflow (SessionRuntime (..))

coordinationHost :: AppEnv -> ObjectiveSettings -> Directory.DirectoryHandle -> ActionAuthorizer -> [AgentDecl] -> DelegationBudget -> Maybe Transfer.WorkspaceProvider -> Worker.CoordinationHost
coordinationHost env settings directory actions agents budget workspaces = Worker.CoordinationHost services authority
  where
    host = objectiveHost settings directory actions
    sessions = SessionRuntime env agents directory (Directory.identityLifecycleAdmission directory) (Just (\actor -> checkpointProvider env actor (host actor))) (Just (\actor -> checkpointRejection env actor (host actor)))
    authority = coordinationAuthority env settings directory actions agents budget
    -- The callback selects authority from the retained session owner. An actor
    -- carried in a submitted intent cannot select another authenticated host.
    ownership = Transfer.OwnershipProvider \intent proof -> do
      actual <- runAppIO env (Sessions.inspectSession intent.sessionId)
      case actual of
        Right (Right (Just (_, binding))) -> (ownershipProvider env binding.parentIdentity (host binding.parentIdentity) workspaces).transfer intent proof
        _ -> pure Transfer.OwnershipUnavailable
    services = TransferServices sessions workspaces (Just ownership)
