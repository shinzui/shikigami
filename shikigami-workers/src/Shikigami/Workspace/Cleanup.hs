-- | Explicit operator cleanup. Terminal execution and settled-effect facts
-- authorize retirement, while fresh exact authority authorizes filesystem IO.
-- Provider metadata/receipts and reserved Unix identities are never deleted.
module Shikigami.Workspace.Cleanup
  ( MaintenanceRuntime (..),
    CleanupError (..),
    listWorkspaces,
    cleanupWorkspace,
  )
where

import Control.Exception (Exception, IOException, catch, throwIO)
import Data.Aeson qualified as Aeson
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Hasql.Transaction (Transaction)
import Kikan.En.Action (AgentAction (InvokeCapabilityTool), mkCapabilityToolTarget)
import Kioku.App (AppEnv, runAppIO)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (ActionAuthorizer (..))
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Prelude
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.CleanupStore
import Shikigami.Workspace.ContainedFile
import Shikigami.Workspace.ProcessPolicy (ProcessProfile (..))
import Shikigami.Workspace.ProcessProfileStore (inspectProcessProfileTx)
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.TransferStore (currentWorkspaceRequestTx)
import Shikigami.Workspace.Types
import System.FilePath ((</>))
import System.Posix.User (getEffectiveUserID)

data MaintenanceRuntime = MaintenanceRuntime
  { appEnv :: !AppEnv,
    storageRoot :: !FilePath,
    authorizer :: !ActionAuthorizer,
    current :: !(AgentIdentity -> IO (Either Text ())),
    afterFiles :: !(IO ())
  }
  deriving stock (Generic)

data CleanupError = CleanupRefused | CleanupUnavailable | CleanupUnresolved
  deriving stock (Eq, Show)

newtype CleanupAbort = CleanupAbort CleanupError deriving stock (Show)

instance Exception CleanupAbort

listWorkspaces :: MaintenanceRuntime -> AgentIdentity -> Maybe Text -> IO (Either CleanupError Aeson.Value)
listWorkspaces runtime actor cursor = protect do
  unless (maybe True validResource cursor) (abort CleanupRefused)
  grant runtime actor "list" (toJSON (runtime.storageRoot, cursor))
  page <- transact runtime (listWorkspacesTx runtime.storageRoot cursor)
  rows <- forM (filter ((== runtime.storageRoot) . (.storageRoot)) page) \binding -> do
    retired <- transact runtime (inspectCleanupTx binding)
    eligible <- transact runtime (cleanupEligibleTx binding)
    pure (Aeson.object ["workspace" Aeson..= binding.workspace, "repository" Aeson..= binding.repository, "base" Aeson..= binding.base, "eligible" Aeson..= eligible, "cleanup" Aeson..= (case retired of Nothing -> "retained"; Just (_, False) -> "pending"; Just (_, True) -> "complete" :: Text)])
  pure (Aeson.object ["workspaces" Aeson..= rows, "next" Aeson..= (if length page == 20 then (.resource) . (.workspace) <$> listToMaybe (reverse page) else Nothing)])

cleanupWorkspace :: MaintenanceRuntime -> AgentIdentity -> WorkspaceRef -> IO (Either CleanupError ())
cleanupWorkspace runtime actor ref = protect do
  unless (ref.provider == "shikigami.workspace/1" && validResource ref.resource) (abort CleanupRefused)
  grant runtime actor "inspect-cleanup" (toJSON ref)
  (binding, state) <- transact runtime (Store.inspectWorkspaceTx ref) >>= maybe (abort CleanupRefused) pure
  unless (state == Ready && binding.storageRoot == runtime.storageRoot) (abort CleanupRefused)
  let metadata = workspaceMetadata binding.storageRoot binding
      directory = binding.storageRoot </> Text.unpack binding.workspace.resource
  needFile =<< checkPrivateDirectory binding.storageRoot
  needFile =<< checkPrivateDirectory metadata
  locked <-
    withWorkspaceLock metadata $
      Right <$> do
        retained <- transact runtime (inspectCleanupTx binding)
        plan <- case retained of
          Just (original, _) -> pure original
          Nothing -> do
            profile <- transact runtime (inspectProcessProfileTx binding.workspace)
            uid <- maybe (fromIntegral <$> getEffectiveUserID) (pure . (.userId) . fst) profile
            files <- anchor (workspaceFiles binding.storageRoot binding)
            scratch <- anchor (workspaceScratch binding.storageRoot binding)
            current <- transact runtime (currentWorkspaceRequestTx binding) >>= maybe (abort CleanupRefused) pure
            pure (CleanupPlan (workspaceBindingDigest binding) files scratch uid (Just current))
        let authorize = grant runtime actor "cleanup" (toJSON (binding, plan))
        authorize
        done <- transact runtime (prepareCleanupTx binding plan) >>= either (const (abort CleanupRefused)) pure
        unless done do
          authorize
          needFile =<< cleanupContainedRoot directory "files" plan.filesTarget plan.userId
          runtime.afterFiles
          authorize
          needFile =<< cleanupContainedRoot directory "scratch" plan.scratchTarget plan.userId
          transact runtime (completeCleanupTx binding plan) >>= either (const (abort CleanupUnresolved)) pure
  either (const (abort CleanupUnresolved)) pure locked

anchor :: FilePath -> IO Text
anchor root = withContainedFile root ".shikigami-cleanup-target" containedTargetIdentity >>= either (const (abort CleanupRefused)) pure

grant :: MaintenanceRuntime -> AgentIdentity -> Text -> Aeson.Value -> IO ()
grant runtime actor kind value = do
  runtime.current actor >>= either (const (abort CleanupRefused)) pure
  principal <- either (const (abort CleanupRefused)) pure (identityText actor)
  let digest = Text.replace ":" "-" (versionedDigest "shikigami.workspace-maintenance/1" value)
  target <- either (const (abort CleanupRefused)) pure (mkCapabilityToolTarget "shikigami.workspace" "maintenance-1" (kind <> "-" <> digest))
  runtime.authorizer.authorize principal (InvokeCapabilityTool target) >>= either (const (abort CleanupRefused)) (const (pure ()))
  runtime.current actor >>= either (const (abort CleanupRefused)) pure

validResource :: Text -> Bool
validResource value = Text.length value == 64 && Text.all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') value

transact :: MaintenanceRuntime -> Transaction a -> IO a
transact runtime action = runAppIO runtime.appEnv (runTransaction action) >>= either (const (abort CleanupUnavailable)) pure

needFile :: Either FileError () -> IO ()
needFile = either (const (abort CleanupUnresolved)) pure

abort :: CleanupError -> IO a
abort = throwIO . CleanupAbort

protect :: IO a -> IO (Either CleanupError a)
protect work = catch (catch (Right <$> work) (\(CleanupAbort err) -> pure (Left err))) (\(_ :: IOException) -> pure (Left CleanupUnresolved))
