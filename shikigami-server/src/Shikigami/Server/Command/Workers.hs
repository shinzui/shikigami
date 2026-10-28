-- | Bounded operator inspection and explicitly keyed control commands.
-- The protected accepted session supplies scope; CLI text never supplies a root
-- or delegation grant. Missing objective/workspace providers stay unavailable.
module Shikigami.Server.Command.Workers (runWorkersInspect, runWorkersControl, runWorkersSend, runWorkersInterrupt, executeWorkerControl) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.ByteString.Lazy.Char8 qualified as LazyChar
import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Shikigami.Action.Authorization (ActionAuthorizer (..))
import Shikigami.Action.Authorization.Config (buildConfiguredActionAuthorizer)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Loader (loadAgentsReport, loadedAgents)
import Shikigami.App.Config (AppConfig (..), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Directory (DirectoryRuntime (..))
import Shikigami.Directory qualified as Directory
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Log qualified as Log
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.WorkerSession.Capability
import Shikigami.WorkerSession.Handoff (TransferServices (..))
import Shikigami.WorkerSession.Store qualified as Store
import Shikigami.WorkerSession.Types
import Shikigami.WorkerSession.Workflow (SessionRuntime (..))
import System.Exit (die)

runWorkersInspect :: Text -> Integer -> Int -> Bool -> AppConfig -> IO ()
runWorkersInspect key after limit _asJson config = do
  env <- environment "workers inspect" config
  result <- runAppIO env (Store.inspectSessionPage (WorkerSessionId key) after limit)
  case result of
    Right (Right (Just page)) -> LazyChar.putStrLn (Aeson.encode page)
    Right (Right Nothing) -> die "worker session was not found"
    _ -> die "worker session inspection was refused; verify the catalog and page bounds"

runWorkersSend :: Text -> Text -> Integer -> Integer -> FilePath -> AppConfig -> IO ()
runWorkersSend session key revision epoch path config = do
  instruction <- readInstruction path
  runWorkersControl key (SendWorker (WorkerSessionId session) revision epoch instruction) config

runWorkersInterrupt :: Text -> Text -> Integer -> Integer -> Text -> FilePath -> AppConfig -> IO ()
runWorkersInterrupt session key revision epoch assignment path config = do
  instruction <- readInstruction path
  runWorkersControl key (InterruptWorker (WorkerSessionId session) revision epoch (AssignmentId assignment) instruction) config

runWorkersControl :: Text -> WorkerCommand -> AppConfig -> IO ()
runWorkersControl key command config = do
  env <- environment "workers control" config
  directory <- Directory.startDirectory Log.silentLogger config.directorySettings >>= either (const (die "worker control directory unavailable")) pure
  authorizer <- buildConfiguredActionAuthorizer Log.silentLogger config >>= either (die . Text.unpack) pure
  -- A recorded session is an authoritative scope source for control of that
  -- session. This cannot create another task or mint another root.
  let session = sessionOf command
  admitted <- runAppIO env do
    Store.inspectSession session >>= \case
      Right (Just (_, binding)) ->
        Store.authorizeSession session binding.parentIdentity (authorizeAdmissionRead authorizer (Directory.identityLifecycleAdmission directory.handle) session binding) >>= \case
          Right access -> Store.loadAdmission access
          Left err -> pure (Left err)
      Right Nothing -> pure (Left SessionMissing)
      Left err -> pure (Left err)
  admission <- case admitted of Right (Right value) -> pure value; _ -> die "accepted worker admission is unavailable"
  memory <- maybe (die "worker admission has no parent memory session") pure admission.context.sessionId
  agents <- loadedAgents <$> loadAgentsReport config.agentsDirectory
  let run = CoordinatorRun ("operator-workers:" <> session.value) admission.context.identity memory admission.context.executionRootId admission.context.executionPermissions
      scope = CoordinationScope 1 run admission.scope.parent admission.delegator admission.context [WorkerSlot admission.scope.workerKey admission.worker admission.identity admission.objective (Just session)] 128 admission.maximumAssignments admission.mailboxLimit
      authority = CoordinationAuthority (\requested -> pure (if requested == run then Right (Just scope) else Left "foreign control scope")) (\requested pinned -> pure (if requested == run && pinned == scopeFingerprint scope then Right scope else Left "control scope unavailable"))
      sessions = SessionRuntime env agents directory.handle (Directory.identityLifecycleAdmission directory.handle) Nothing
      host = CoordinationHost (TransferServices sessions Nothing Nothing) authority
  result <- executeWorkerControl host authorizer scope (OperationId key) command
  case result of
    Right reply -> LazyChar.putStrLn (Aeson.encode reply)
    Left _ -> die "worker command refused; fresh parent authority and any required objective/workspace providers must be configured"

-- | Qualified hosts use the exact same owner as Flow and Skill calls. The
-- default CLI composition has no invented IR-11/IR-13 provider.
executeWorkerControl :: CoordinationHost -> ActionAuthorizer -> CoordinationScope -> OperationId -> WorkerCommand -> IO (Either SessionError WorkerReply)
executeWorkerControl host authorizer scope key command = do
  result <- runAppIO host.services.sessions.appEnv do
    resolveGrant host authorizer scope.run (Just (scopeFingerprint scope)) >>= \case
      Right (Just grant) -> executeCommand host authorizer grant key command
      Right Nothing -> pure (Left SessionOwnerRefused)
      Left err -> pure (Left err)
  pure (either (const (Left SessionStorageUnavailable)) id result)

environment :: Text -> AppConfig -> IO AppEnv
environment label config = do
  connection <- revealSecretText <$> requireDatabaseUrl label config
  verifyShikigamiMigrations connection
  tracer <- noopTracer
  pure (AppEnv (defaultConnectionSettings connection) tracer Nothing)

readInstruction :: FilePath -> IO WorkerInstruction
readInstruction path = do
  bytes <- Lazy.readFile path
  if Lazy.length bytes > 1048576
    then die "worker instruction exceeds 1 MiB"
    else
      either (const (die "invalid closed worker instruction JSON")) pure (Aeson.eitherDecode bytes)

sessionOf :: WorkerCommand -> WorkerSessionId
sessionOf = \case
  FindWorker {} -> error "operator find requires an authoritative objective association"
  SendWorker {sessionId} -> sessionId
  InspectWorker {sessionId} -> sessionId
  ReadWorkerEvents {sessionId} -> sessionId
  ReadWorkerResult {sessionId} -> sessionId
  InterruptWorker {sessionId} -> sessionId
  CancelWorker {sessionId} -> sessionId
  TransferWorker {sessionId} -> sessionId
  ReconcileWorker {sessionId} -> sessionId
  IntegrateWorkerEvents {sessionId} -> sessionId
