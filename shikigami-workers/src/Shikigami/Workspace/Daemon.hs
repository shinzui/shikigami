-- | Independent production composition. Queue workers communicate through the
-- manager-owned listener; only this process selects retained rules and launches.
module Shikigami.Workspace.Daemon (runWorkspaceSupervisor) where

import Control.Concurrent.Async (race)
import Control.Exception (bracket)
import Kiroku.Store.Connection qualified as StoreConnection
import Network.Socket qualified as Socket
import Shikigami.Action.Authorization.Config (buildConfiguredActionAuthorizer)
import Shikigami.App (AppEnv (..))
import Shikigami.App.Config (AppConfig (..), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Attestation.Resolve qualified as Profile
import Shikigami.Directory (DirectoryRuntime (..), identityLifecycleAdmission, startDirectory)
import Shikigami.Execution.SelectionRuntime (currentExecutionAuthority)
import Shikigami.Execution.Transcript (ExecutionSnapshot (..))
import Shikigami.Inspection.Runtime (withInspectionRuntime)
import Shikigami.Inspection.Store (withObservedStore)
import Shikigami.Log qualified as Log
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Prelude
import Shikigami.Runtime (registerRuntimeCatalog, runtimeConnectionSettings)
import Shikigami.Telemetry (withRunTelemetry)
import Shikigami.Workspace.Profile (retainedProcessRule)
import Shikigami.Workspace.Rpc (RpcPolicy (..), getSystemdListener)
import Shikigami.Workspace.Service (serveSupervisor)
import Shikigami.Workspace.Settings (WorkspaceSupervisorSettings (..))
import Shikigami.Workspace.Supervisor (SupervisorRuntime (..), systemdSupervisorBackend)
import System.Exit (exitFailure)

runWorkspaceSupervisor :: AppConfig -> IO ()
runWorkspaceSupervisor config = do
  -- Adoption consumes LISTEN_* before telemetry or application threads start.
  settings <- maybe exitFailure pure config.workspaceSupervisorSettings
  acquired <- getSystemdListener settings.socketPath
  listener <- case acquired of
    Left _ -> do
      logger <- Log.newStderrLogger Log.Info
      Log.logError logger "workspace.supervisor.listener_unavailable" []
      exitFailure
    Right socket -> pure socket
  bracket (pure listener) Socket.close \socket -> do
    logger <- Log.newStderrLogger Log.Info
    let refuse :: Text -> IO a
        refuse event = Log.logError logger event [] >> exitFailure
    connection <- revealSecretText <$> requireDatabaseUrl "shikigami-workspace-supervisor" config
    verifyShikigamiMigrations connection
    withRunTelemetry "shikigami.workspace-supervisor" \tracer metrics _ -> do
      let connections = runtimeConnectionSettings logger metrics connection
      withObservedStore tracer connections \store storeMetrics -> do
        registerRuntimeCatalog store
        withInspectionRuntime config.inspection logger connections store storeMetrics [] \_ -> do
          authorizer <- buildConfiguredActionAuthorizer logger config >>= either (const (refuse "workspace.supervisor.authorization_invalid")) pure
          directory <- startDirectory logger config.directorySettings >>= either (const (refuse "workspace.supervisor.directory_invalid")) pure
          let appEnv = AppEnv {connectionSettings = connections, tracer, metrics, store = Just store}
              resolveProfile profile version = do
                now <- getCurrentTime
                Profile.resolveProfile (Profile.postgresProfileStore (StoreConnection.pool store)) now profile version
              active snapshot = currentExecutionAuthority (identityLifecycleAdmission directory.handle snapshot.identity) snapshot.sanctionedProfile resolveProfile
              runtime = SupervisorRuntime appEnv authorizer (identityLifecycleAdmission directory.handle) active (retainedProcessRule appEnv) systemdSupervisorBackend
              service = void (serveSupervisor (RpcPolicy settings.users settings.workers settings.timeoutSeconds) socket runtime)
          Log.logInfo logger "workspace.supervisor.started" []
          case directory.refresher of
            Nothing -> service
            Just refresh -> void (race service refresh)
          refuse "workspace.supervisor.stopped"
