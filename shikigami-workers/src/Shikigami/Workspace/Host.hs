-- | Pre-model allocation and reviewed instruction admission, shared by the
-- file-only host and the explicitly configured supervised host.
module Shikigami.Workspace.Host (fileWorkspaceHost, governedWorkspaceHost, governedWorkspaceHostWithTransfers) where

import Data.Generics.Labels ()
import Data.Time (getCurrentTime)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (ActionAuthorizer (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Principal (identityText)
import Shikigami.App (runAppIO)
import Shikigami.Capability.Catalog
import Shikigami.Capability.Overlay (CapabilityDescriptor (..))
import Shikigami.Capability.Provider
import Shikigami.Execution.Policy.Limits (policyNumber)
import Shikigami.Execution.Policy.Types (HarnessPolicy (..))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Start (SkillAssignment (..))
import Shikigami.Execution.Transcript (ExecutionError (..))
import Shikigami.Prelude
import Shikigami.StateRevision (initialRevision)
import Shikigami.Workspace.Admission (WorkspaceHost (..))
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Catalog (ResolvedRepository, repositoryBase, repositoryIdentity, repositoryPolicyRevision, repositorySource)
import Shikigami.Workspace.ContainedFile (checkPrivateDirectory, withWorkspaceLock)
import Shikigami.Workspace.FileProvider
import Shikigami.Workspace.InstructionLoader
import Shikigami.Workspace.Instructions (WorkspaceAdmission (..), bundleFiles, transferableFilePolicy)
import Shikigami.Workspace.Profile (retainedFileProfile)
import Shikigami.Workspace.Provider
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.TransferStore (SessionChild (..))
import Shikigami.Workspace.TransferStore qualified as Transfers
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value

-- | The selector and admission callback are trusted process configuration.
-- The selector must resolve a canonical operator catalog entry. The callback
-- must check current lifecycle and retained profile authority; file target
-- policy is supplied by FileRuntime.admitTarget. There is no allow-all default.
fileWorkspaceHost :: FileRuntime -> FilePath -> (SkillAssignment -> IO (Either Text ResolvedRepository)) -> (SkillAssignment -> IO (Either Text ())) -> Either Text WorkspaceHost
fileWorkspaceHost runtime = governedWorkspaceHost runtime [workspaceEditAdapter runtime] [] (\_ _ -> pure . Right)

-- Historical adapters are available only for protected snapshots that already
-- pinned them. New resolution uses only the selected descriptors.
governedWorkspaceHost :: FileRuntime -> [DurableAdapter] -> [DurableAdapter] -> (SkillAssignment -> WorkspaceBinding -> WorkspaceAdmission -> IO (Either Text WorkspaceAdmission)) -> FilePath -> (SkillAssignment -> IO (Either Text ResolvedRepository)) -> (SkillAssignment -> IO (Either Text ())) -> Either Text WorkspaceHost
governedWorkspaceHost = workspaceHostFor False

governedWorkspaceHostWithTransfers :: FileRuntime -> [DurableAdapter] -> [DurableAdapter] -> (SkillAssignment -> WorkspaceBinding -> WorkspaceAdmission -> IO (Either Text WorkspaceAdmission)) -> FilePath -> (SkillAssignment -> IO (Either Text ResolvedRepository)) -> (SkillAssignment -> IO (Either Text ())) -> Either Text WorkspaceHost
governedWorkspaceHostWithTransfers = workspaceHostFor True

workspaceHostFor :: Bool -> FileRuntime -> [DurableAdapter] -> [DurableAdapter] -> (SkillAssignment -> WorkspaceBinding -> WorkspaceAdmission -> IO (Either Text WorkspaceAdmission)) -> FilePath -> (SkillAssignment -> IO (Either Text ResolvedRepository)) -> (SkillAssignment -> IO (Either Text ())) -> Either Text WorkspaceHost
workspaceHostFor transferable runtime selected historical prepare storageRoot select currentAuthority = do
  let descriptors = map (.descriptor) selected
  catalog <- either (const (Left "workspace catalog is invalid")) Right (mkCapabilityCatalog descriptors)
  providers <- either (const (Left "workspace adapter installation refused")) Right (installDurableAdapters (selected <> historical) emptyCapabilityProviderRegistry)
  let capabilities = CapabilityRuntime catalog providers (\_ descriptor -> if descriptor `elem` (descriptors <> map (.descriptor) historical) then Right () else Left (CapabilityAuthorizationDenied descriptor.capability "workspace capability is unavailable"))
  pure (WorkspaceHost capabilities load)
  where
    refused = Left (ExecutionPolicyRefused "workspace admission refused")
    load assignment = case (assignment.selection.rootId, assignment.policy, identityText assignment.identity) of
      (Just root, Right policy, Right principal) -> do
        selected <- select assignment
        mapped <- mapping assignment
        allowed <- gate assignment root
        case (selected, mapped, allowed) of
          (Right repository, Right (Just child), Right ()) | child.epoch > initialRevision -> do
            retained <- runAppIO runtime.appEnv (runTransaction (Transfers.successorWorkspaceTx child))
            case retained of
              Right (Right binding) -> reuse False assignment root policy principal repository child binding
              _ -> pure refused
          (Right repository, Right (Just child), Right ()) | child.sequence > initialRevision -> do
            retained <- runAppIO runtime.appEnv (runTransaction (Transfers.findFollowupWorkspaceTx assignment.runId child storageRoot repository))
            case retained of
              Right (Right (Just binding)) -> reuse True assignment root policy principal repository child binding
              Right (Right Nothing) -> allocate assignment root policy principal repository (Just child)
              _ -> pure refused
          (Right repository, Right mappedChild, Right ()) -> allocate assignment root policy principal repository mappedChild
          _ -> pure refused
      _ -> pure refused
    reuse followup assignment root policy principal repository child binding
      | binding.repository /= repositoryIdentity repository || binding.base /= repositoryBase repository || binding.policyRevision /= repositoryPolicyRevision repository || binding.source /= repositorySource repository || workspaceLocatorPath binding.storageRoot /= storageRoot = pure refused
      | otherwise = do
          authority <- case workspaceAllocationAction binding assignment.selection.assignmentId of
            Left _ -> pure (Left "workspace admission refused")
            Right action -> runtime.authorizer.authorize (declarationCoordinate principal) action <&> either (const (Left "workspace admission refused")) (const (Right ()))
          fresh <- gate assignment root
          case (authority, fresh) of
            (Right (), Right ()) -> do
              loaded <- loadWorkspaceAdmission binding assignment.selection.assignmentId (min 65536 (policyNumber policy.contextBytes))
              case loaded of
                Left _ -> pure refused
                Right original -> do
                  let admission = original & #runId .~ assignment.runId & #owner .~ child.owner & #epoch .~ child.epoch & #filePolicy .~ Just transferableFilePolicy
                  reviewed <- runtime.admitTarget binding admission (bundleFiles admission.instructions) (workspaceCoordinate ("admit")) (workspaceCoordinate (""))
                  case reviewed of
                    Left _ -> pure refused
                    Right () -> do
                      prepared <- prepare assignment binding admission
                      case prepared of
                        Left _ -> pure refused
                        Right accepted -> admitExisting followup assignment binding accepted
            _ -> pure refused
    allocate assignment root policy principal repository mappedChild = do
      let request = WorkspaceRequest assignment.runId (fmap (\child -> (child.session, child.assignment)) mappedChild) root assignment.identity assignment.identity (maybe initialRevision (.epoch) mappedChild)
      reserved <- runAppIO runtime.appEnv (runTransaction (Store.reserveWorkspaceTx storageRoot request repository))
      case reserved of
        Right (Right (binding, state)) -> case workspaceAllocationAction binding assignment.selection.assignmentId of
          Left _ -> pure refused
          Right action -> do
            authority <- runtime.authorizer.authorize (declarationCoordinate principal) action
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
                        loaded <- loadWorkspaceAdmission binding assignment.selection.assignmentId (min 65536 (policyNumber policy.contextBytes))
                        case loaded of
                          Left _ -> pure refused
                          Right original -> do
                            let admission = if transferable then original & #filePolicy .~ Just transferableFilePolicy else original
                            reviewed <- runtime.admitTarget binding admission (bundleFiles admission.instructions) (workspaceCoordinate "admit") (workspaceCoordinate "")
                            case reviewed of
                              Left _ -> pure refused
                              Right () -> either (const refused) Right <$> prepare assignment binding admission
                      Left _ -> pure (Left ExecutionStorageUnavailable)
                      _ -> pure refused
              _ -> pure refused
        Left _ -> pure (Left ExecutionStorageUnavailable)
        _ -> pure refused
    gate assignment root = do
      authority <- currentAuthority assignment
      mapped <- mapping assignment
      inspected <- runAppIO runtime.appEnv (Roots.inspectRoot root)
      now <- getCurrentTime
      pure do
        authority
        _ <- mapped
        state <- either (const (Left "workspace resource storage unavailable")) (either (const (Left "workspace root unavailable")) Right) inspected
        either (const (Left "workspace root refused")) Right (Resources.checkRoot now state.revision state)
    mapping assignment
      | not transferable = pure (Right Nothing)
      | otherwise = do
          retained <- runAppIO runtime.appEnv (runTransaction (Transfers.lookupSessionChildTx assignment.runId))
          pure case retained of
            Right (Right child) | maybe True (\value -> value.owner == assignment.identity && Just value.rootId == assignment.selection.rootId) child -> Right child
            _ -> Left "workspace session admission refused"
    admitExisting followup assignment binding admission = do
      let metadata = workspaceMetadata (workspaceLocatorPath binding.storageRoot) binding
      rootPrivate <- checkPrivateDirectory (workspaceLocatorPath binding.storageRoot)
      metadataPrivate <- checkPrivateDirectory metadata
      case rootPrivate >> metadataPrivate of
        Left _ -> pure refused
        Right () -> do
          result <- withWorkspaceLock metadata do
            current <- gate assignment admission.rootId
            profile <- retainedFileProfile runtime.appEnv binding admission
            case (current, profile, identityText admission.owner) of
              (Right (), Right retained, Right principal) -> case (if followup then workspaceFollowupAdmissionAction else workspaceSuccessorAdmissionAction) binding admission retained of
                Left _ -> pure (Right refused)
                Right action -> do
                  authority <- runtime.authorizer.authorize (declarationCoordinate principal) action
                  fresh <- gate assignment admission.rootId
                  case (authority, fresh) of
                    (Right _, Right ()) -> do
                      saved <- runAppIO runtime.appEnv (runTransaction ((if followup then Transfers.admitFollowupTx else Transfers.admitSuccessorTx) binding admission))
                      pure (Right (case saved of Right (Right ()) -> Right admission; _ -> refused))
                    _ -> pure (Right refused)
              _ -> pure (Right refused)
          pure (either (const refused) id result)
