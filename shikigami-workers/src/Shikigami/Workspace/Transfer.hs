-- | Concrete workspace-side transfer owner. Freeze shares every writer's OS
-- lock; process cancellation and factual receipt recovery remain independent
-- of the coordinator and queue worker. No objective receipt is fabricated.
module Shikigami.Workspace.Transfer (workspaceTransferProvider) where

import Control.Exception (Exception, IOException, catch, throwIO)
import Effectful (Eff)
import Hasql.Transaction (Transaction)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (ActionAuthorizer (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Prelude
import Shikigami.WorkerSession.Transfer
import Shikigami.Workspace.Allocation (workspaceMetadata)
import Shikigami.Workspace.ContainedFile
import Shikigami.Workspace.FileProvider (publishFileReceipt)
import Shikigami.Workspace.GitProvider (publishGitReceipt)
import Shikigami.Workspace.Provider
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Supervisor
import Shikigami.Workspace.TransferStore qualified as Transfers
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value

newtype TransferAbort = TransferAbort FenceOutcome deriving stock (Show)

instance Exception TransferAbort

workspaceTransferProvider :: SupervisorRuntime -> WorkspaceProvider
workspaceTransferProvider runtime = WorkspaceProvider reconcile admit
  where
    env = runtime.appEnv
    reconcile intent =
      either id id <$> protect do
        binding <- loadBinding intent.workspace
        known <- transaction env (Transfers.inspectTransferTx binding intent.oldEpoch) >>= either (const (abort FenceConflict)) pure
        case known of
          Just (original, Just proof) | original == intent && matchesFence intent proof -> pure (FencedAndSettled proof)
          Just (original, _) | original /= intent -> abort FenceConflict
          _ -> do
            frozen <- locked binding do
              -- Recheck after acquiring the lock: an independently admitted
              -- freeze can now be observed without requesting new authority.
              retained <- transaction env (Transfers.inspectTransferTx binding intent.oldEpoch) >>= either (const (abort FenceConflict)) pure
              case retained of
                Nothing -> do
                  authority intent.actor binding
                  action <- either (const (abort FenceConflict)) pure (workspaceTransferAction binding intent)
                  principal <- either (const (abort FenceConflict)) pure (identityText intent.actor)
                  runtime.authorizer.authorize (declarationCoordinate principal) action >>= either (const (abort FenceUnavailable)) (const (pure ()))
                  authority intent.actor binding
                _ -> pure ()
              transaction env (Transfers.beginTransferTx binding intent) >>= either (const (abort FenceConflict)) pure
            case frozen of
              Just proof -> pure (FencedAndSettled proof)
              Nothing -> do
                pending <- transaction env (Transfers.pendingWorkspaceOperationsTx binding) >>= either (const (abort FenceUnresolved)) pure
                forM_ pending \(operation, kind) -> case kind of
                  "file" -> void (publishFileReceipt env operation)
                  "git" -> void (publishGitReceipt env operation)
                  "process" -> void (publishProcessReceipt runtime operation)
                  _ -> pure ()
                result <- locked binding (transaction env (Transfers.retainFenceTx binding intent))
                pure (either (const FenceUnresolved) FencedAndSettled result)
    admit workspace session owner epoch operation = do
      result <- protect do
        binding <- loadBinding workspace
        locked binding do
          authority owner binding
          action <- either (const (abort FenceConflict)) pure (workspaceWriteAdmissionAction binding workspace session owner epoch operation)
          principal <- either (const (abort FenceConflict)) pure (identityText owner)
          runtime.authorizer.authorize (declarationCoordinate principal) action >>= either (const (abort FenceUnavailable)) (const (pure ()))
          authority owner binding
          transaction env (Transfers.checkSessionWriteTx binding session owner epoch operation) >>= either (const (abort FenceConflict)) pure
      pure (either (const (Left "workspace write admission refused")) Right result)
    loadBinding workspace =
      transaction env (Store.inspectWorkspaceTx workspace) >>= \case
        Right (Just (binding, Ready)) -> pure binding
        _ -> abort FenceUnavailable
    authority :: AgentIdentity -> WorkspaceBinding -> IO ()
    authority identity binding = do
      runtime.replayAuthority identity >>= either (const (abort FenceUnavailable)) pure
      root <- application env (Roots.inspectRoot binding.request.rootId) >>= either (const (abort FenceUnavailable)) pure
      now <- getCurrentTime
      either (const (abort FenceUnavailable)) pure (Resources.checkRoot now root.revision root)

locked :: WorkspaceBinding -> IO a -> IO a
locked binding action = do
  let metadata = workspaceMetadata (workspaceLocatorPath binding.storageRoot) binding
  forM_ [workspaceLocatorPath binding.storageRoot, metadata] \directory -> checkPrivateDirectory directory >>= either (const (abort FenceUnavailable)) pure
  result <- withWorkspaceLock metadata (Right <$> action)
  either (const (abort FenceUnresolved)) pure result

application :: AppEnv -> Eff AppEffects a -> IO a
application env action = runAppIO env action >>= either (const (abort FenceUnavailable)) pure

transaction :: AppEnv -> Transaction a -> IO a
transaction env = application env . runTransaction

abort :: FenceOutcome -> IO a
abort = throwIO . TransferAbort

protect :: IO a -> IO (Either FenceOutcome a)
protect action = catch (catch (Right <$> action) (\(TransferAbort outcome) -> pure (Left outcome))) (\(_ :: IOException) -> pure (Left FenceUnresolved))
