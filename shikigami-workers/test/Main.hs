module Main (main) where

import Shikigami.Agent.RunJob.WorkerSpec qualified as RunJobWorkerSpec
import Shikigami.AgentRun.StatusSpec qualified as StatusSpec
import Shikigami.Health.WorkerSpec qualified as HealthWorkerSpec
import Shikigami.Migrations.TestSupport (withShikigamiMigratedSuite)
import Shikigami.SchedulerSpec qualified as SchedulerSpec
import Shikigami.StreamInboxSpec qualified as StreamInboxSpec
import Shikigami.TelemetrySpec qualified as TelemetrySpec
import Shikigami.TimerRecoverySpec qualified as TimerRecoverySpec
import Shikigami.Workers.CommandSpec qualified as CommandSpec
import Shikigami.Workers.SupervisionSpec qualified as SupervisionSpec
import Shikigami.WorkspaceContainedFileSpec qualified as WorkspaceContainedFileSpec
import Shikigami.WorkspaceFileProviderSpec qualified as WorkspaceFileProviderSpec
import Shikigami.WorkspaceProcessStoreSpec qualified as WorkspaceProcessStoreSpec
import Shikigami.WorkspaceRpcSpec qualified as WorkspaceRpcSpec
import Shikigami.WorkspaceStoreSpec qualified as WorkspaceStoreSpec
import Shikigami.WorkspaceSupervisorSpec qualified as WorkspaceSupervisorSpec
import Shikigami.WorkspaceSystemdSpec qualified as WorkspaceSystemdSpec
import Shikigami.WorkspaceWorkflowSpec qualified as WorkspaceWorkflowSpec
import System.Environment (lookupEnv)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = do
  fixture <- lookupEnv "SHIKIGAMI_GRACEFUL_SHUTDOWN_FIXTURE"
  case fixture of
    Just "1" -> SupervisionSpec.gracefulShutdownFixture
    _ -> withShikigamiMigratedSuite \databaseFixture ->
      defaultMain
        ( testGroup
            "shikigami-workers"
            [ WorkspaceSupervisorSpec.tests databaseFixture,
              WorkspaceRpcSpec.tests,
              WorkspaceSystemdSpec.tests,
              WorkspaceProcessStoreSpec.tests databaseFixture,
              WorkspaceWorkflowSpec.tests databaseFixture,
              WorkspaceFileProviderSpec.tests databaseFixture,
              WorkspaceContainedFileSpec.tests,
              WorkspaceStoreSpec.tests databaseFixture,
              CommandSpec.tests,
              HealthWorkerSpec.tests,
              RunJobWorkerSpec.tests databaseFixture,
              StatusSpec.tests databaseFixture,
              SchedulerSpec.tests databaseFixture,
              StreamInboxSpec.tests databaseFixture,
              TimerRecoverySpec.tests databaseFixture,
              TelemetrySpec.tests,
              SupervisionSpec.tests
            ]
        )
