-- | Bounded operator actions in the existing resource-owning worker binary.
module Shikigami.Workspace.Maintenance (WorkspaceMaintenance (..), runWorkspaceMaintenance) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Bytes
import Kiroku.Store.Connection (defaultConnectionSettings)
import Shikigami.Action.Authorization.Config (buildConfiguredActionAuthorizer)
import Shikigami.Agent.Principal (AgentIdentity (VerifiedIdentity), mkAgentPrincipal)
import Shikigami.App (AppEnv (..), noopTracer)
import Shikigami.App.Config (AppConfig (..), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Directory (DirectoryRuntime (..), identityLifecycleAdmission, startDirectory)
import Shikigami.Log qualified as Log
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Prelude hiding ((.=))
import Shikigami.Workspace.Cleanup
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Settings (WorkspaceSettings (..))
import System.Exit (exitFailure)

data WorkspaceMaintenance = ListWorkspaces !(Maybe Text) | CleanupWorkspace !Text
  deriving stock (Eq, Show)

runWorkspaceMaintenance :: Text -> WorkspaceMaintenance -> AppConfig -> IO ()
runWorkspaceMaintenance actor operation config = do
  logger <- Log.newStderrLogger Log.Info
  let refuse :: IO a
      refuse = Log.logError logger "workspace.maintenance.refused" [] >> exitFailure
  principal <- either (const refuse) (pure . VerifiedIdentity) (mkAgentPrincipal actor)
  settings <- maybe refuse pure config.workspaceSettings
  connection <- revealSecretText <$> requireDatabaseUrl "shikigami-worker" config
  verifyShikigamiMigrations connection
  tracer <- noopTracer
  authorizer <- buildConfiguredActionAuthorizer logger config >>= either (const refuse) pure
  directory <- startDirectory logger config.directorySettings >>= either (const refuse) pure
  let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}
      runtime = MaintenanceRuntime appEnv settings.storageRoot authorizer (identityLifecycleAdmission directory.handle) (pure ())
  output <- case operation of
    ListWorkspaces cursor -> listWorkspaces runtime principal cursor
    CleanupWorkspace resource -> fmap (const (Aeson.object ["workspace" .= WorkspaceRef "shikigami.workspace/1" resource, "cleanup" .= ("complete" :: Text)])) <$> cleanupWorkspace runtime principal (WorkspaceRef "shikigami.workspace/1" resource)
  either (const refuse) (\value -> Bytes.putStr (Aeson.encode value <> "\n")) output
