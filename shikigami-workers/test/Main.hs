module Main (main) where

import Data.Text qualified as Text
import Shikigami.AdmitProposalSpec qualified as AdmitProposalSpec
import Shikigami.Agent.RunJob.WorkerSpec qualified as RunJobWorkerSpec
import Shikigami.AgentRun.StatusSpec qualified as StatusSpec
import Shikigami.ExecutionCapacitySpec qualified as ExecutionCapacitySpec
import Shikigami.Health.SupervisionSpec qualified as SupervisionSpec
import Shikigami.Health.WorkerSpec qualified as HealthWorkerSpec
import Shikigami.InitiativeAcceptanceSpec qualified as InitiativeAcceptanceSpec
import Shikigami.Inspection.ConsumerSpec qualified as InspectionSpec
import Shikigami.Integration.ConsumerRuntimeSpec qualified as ConsumerAppSpec
import Shikigami.Migrations.TestSupport (withShikigamiMigratedSuite)
import Shikigami.ObjectiveTrackerWorkerSpec qualified as ObjectiveTrackerWorkerSpec
import Shikigami.ProposeWorkSpec qualified as ProposeWorkSpec
import Shikigami.SchedulerSpec qualified as SchedulerSpec
import Shikigami.StreamInboxSpec qualified as StreamInboxSpec
import Shikigami.TelemetrySpec qualified as TelemetrySpec
import Shikigami.TimerRecoverySpec qualified as TimerRecoverySpec
import Shikigami.Workers.CommandSpec qualified as CommandSpec
import Shikigami.WorkspaceContainedFileSpec qualified as WorkspaceContainedFileSpec
import Shikigami.WorkspaceFileProviderSpec qualified as WorkspaceFileProviderSpec
import Shikigami.WorkspaceGitObjectsSpec qualified as WorkspaceGitObjectsSpec
import Shikigami.WorkspaceGitProviderSpec qualified as WorkspaceGitProviderSpec
import Shikigami.WorkspaceGitStoreSpec qualified as WorkspaceGitStoreSpec
import Shikigami.WorkspaceProcessProfileSpec qualified as WorkspaceProcessProfileSpec
import Shikigami.WorkspaceProcessStoreSpec qualified as WorkspaceProcessStoreSpec
import Shikigami.WorkspaceProvisionSpec qualified as WorkspaceProvisionSpec
import Shikigami.WorkspaceRpcSpec qualified as WorkspaceRpcSpec
import Shikigami.WorkspaceStoreSpec qualified as WorkspaceStoreSpec
import Shikigami.WorkspaceSupervisorSpec qualified as WorkspaceSupervisorSpec
import Shikigami.WorkspaceSystemdSpec qualified as WorkspaceSystemdSpec
import Shikigami.WorkspaceTransferSpec qualified as WorkspaceTransferSpec
import Shikigami.WorkspaceWorkflowSpec qualified as WorkspaceWorkflowSpec
import System.Environment (getArgs, lookupEnv)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--root-capacity-claim", ticket] -> ExecutionCapacitySpec.rootCapacityClaimProcess (Text.pack ticket)
    ["--capacity-claim", ticket] -> ExecutionCapacitySpec.capacityClaimProcess (Text.pack ticket)
    _ -> suite

suite :: IO ()
suite = do
  fixture <- lookupEnv "SHIKIGAMI_GRACEFUL_SHUTDOWN_FIXTURE"
  case fixture of
    Just "1" -> SupervisionSpec.gracefulShutdownFixture
    _ -> withShikigamiMigratedSuite \databaseFixture ->
      defaultMain
        ( testGroup
            "shikigami-workers"
            [ ExecutionCapacitySpec.tests databaseFixture,
              WorkspaceGitProviderSpec.tests databaseFixture,
              WorkspaceTransferSpec.tests databaseFixture,
              WorkspaceGitStoreSpec.tests databaseFixture,
              WorkspaceGitObjectsSpec.tests,
              WorkspaceSupervisorSpec.tests databaseFixture,
              WorkspaceRpcSpec.tests,
              WorkspaceSystemdSpec.tests,
              WorkspaceProcessStoreSpec.tests databaseFixture,
              WorkspaceProcessProfileSpec.tests databaseFixture,
              WorkspaceProvisionSpec.tests databaseFixture,
              WorkspaceWorkflowSpec.tests databaseFixture,
              WorkspaceFileProviderSpec.tests databaseFixture,
              WorkspaceContainedFileSpec.tests,
              WorkspaceStoreSpec.tests databaseFixture,
              ObjectiveTrackerWorkerSpec.tests databaseFixture,
              CommandSpec.tests,
              ConsumerAppSpec.tests,
              InspectionSpec.tests databaseFixture,
              HealthWorkerSpec.tests,
              RunJobWorkerSpec.tests databaseFixture,
              StatusSpec.tests databaseFixture,
              SchedulerSpec.tests databaseFixture,
              StreamInboxSpec.tests databaseFixture,
              ProposeWorkSpec.tests databaseFixture,
              AdmitProposalSpec.tests databaseFixture,
              InitiativeAcceptanceSpec.tests databaseFixture,
              TimerRecoverySpec.tests databaseFixture,
              TelemetrySpec.tests,
              SupervisionSpec.tests
            ]
        )
