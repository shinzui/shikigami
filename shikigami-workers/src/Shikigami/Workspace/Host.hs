-- | Explicit operator installation for the file-only workspace backend.
-- Process admission is separate and remains unavailable on this host.
module Shikigami.Workspace.Host (fileWorkspaceHost) where

import Data.Time (getCurrentTime)
import Kioku.App (runAppIO)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (ActionAuthorizer (..))
import Shikigami.Agent.Principal (identityText)
import Shikigami.Capability.Catalog
import Shikigami.Capability.Overlay (CapabilityDescriptor (..))
import Shikigami.Capability.Provider
import Shikigami.Execution.Policy.Types (HarnessPolicy (..))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Start (SkillAssignment (..))
import Shikigami.Execution.Transcript (ExecutionError (..))
import Shikigami.Prelude
import Shikigami.Store.ExecutionResources qualified as Roots
import Shikigami.Workspace.Admission (WorkspaceHost (..))
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Catalog (ResolvedRepository)
import Shikigami.Workspace.FileProvider
import Shikigami.Workspace.InstructionLoader
import Shikigami.Workspace.Instructions (WorkspaceAdmission (..), bundleFiles)
import Shikigami.Workspace.Provider
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Types

-- | The selector and admission callback are trusted process configuration.
-- The selector must resolve a canonical operator catalog entry. The callback
-- must check current lifecycle and retained profile authority; file target
-- policy is supplied by FileRuntime.admitTarget. There is no allow-all default.
fileWorkspaceHost :: FileRuntime -> FilePath -> (SkillAssignment -> IO (Either Text ResolvedRepository)) -> (SkillAssignment -> IO (Either Text ())) -> Either Text WorkspaceHost
fileWorkspaceHost runtime storageRoot select currentAuthority = do
  catalog <- either (const (Left "workspace catalog is invalid")) Right (mkCapabilityCatalog [workspaceEditDescriptor])
  providers <- either (const (Left "workspace adapter installation refused")) Right (installDurableAdapters [workspaceEditAdapter runtime] emptyCapabilityProviderRegistry)
  let capabilities = CapabilityRuntime catalog providers (\_ descriptor -> if descriptor == workspaceEditDescriptor then Right () else Left (CapabilityAuthorizationDenied descriptor.capability "workspace capability is unavailable"))
  pure (WorkspaceHost capabilities load)
  where
    refused = Left (ExecutionPolicyRefused "workspace admission refused")
    load assignment = case (assignment.selection.rootId, assignment.policy, identityText assignment.identity) of
      (Just root, Right policy, Right principal) -> do
        selected <- select assignment
        allowed <- gate assignment root
        case (selected, allowed) of
          (Right repository, Right ()) -> do
            reserved <- runAppIO runtime.appEnv (runTransaction (Store.reserveWorkspaceTx storageRoot (WorkspaceRequest assignment.runId Nothing root assignment.identity assignment.identity 0) repository))
            case reserved of
              Right (Right (binding, state)) -> case workspaceAllocationAction binding assignment.selection.assignmentId of
                Left _ -> pure refused
                Right action -> do
                  authority <- runtime.authorizer.authorize principal action
                  fresh <- gate assignment root
                  case (authority, fresh) of
                    (Right _, Right ()) -> do
                      allocated <- allocateWorkspace storageRoot binding state
                      case allocated of
                        Left _ -> pure refused
                        Right () -> do
                          ready <- runAppIO runtime.appEnv (runTransaction (Store.markWorkspaceReadyTx binding))
                          case ready of
                            Right (Right ()) -> do
                              loaded <- loadWorkspaceAdmission binding assignment.selection.assignmentId (min 65536 policy.contextBytes)
                              case loaded of
                                Left _ -> pure refused
                                Right admission -> do
                                  reviewed <- runtime.admitTarget binding admission (bundleFiles admission.instructions) "admit" ""
                                  pure (either (const refused) (const (Right admission)) reviewed)
                            Left _ -> pure (Left ExecutionStorageUnavailable)
                            _ -> pure refused
                    _ -> pure refused
              Left _ -> pure (Left ExecutionStorageUnavailable)
              _ -> pure refused
          _ -> pure refused
      _ -> pure refused
    gate assignment root = do
      authority <- currentAuthority assignment
      inspected <- runAppIO runtime.appEnv (Roots.inspectRoot root)
      now <- getCurrentTime
      pure do
        authority
        state <- either (const (Left "workspace resource storage unavailable")) (either (const (Left "workspace root unavailable")) Right) inspected
        either (const (Left "workspace root refused")) Right (Resources.checkRoot now state.revision state)
