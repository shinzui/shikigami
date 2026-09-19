module Main (main) where

import Shikigami.Agent.RunJob.WorkerSpec qualified as RunJobWorkerSpec
import Shikigami.Health.WorkerSpec qualified as HealthWorkerSpec
import Shikigami.Migrations.TestSupport (withShikigamiMigratedSuite)
import Shikigami.SchedulerSpec qualified as SchedulerSpec
import Shikigami.StreamInboxSpec qualified as StreamInboxSpec
import Shikigami.TelemetrySpec qualified as TelemetrySpec
import Shikigami.TimerRecoverySpec qualified as TimerRecoverySpec
import Shikigami.Workers.CommandSpec qualified as CommandSpec
import Shikigami.Workers.SupervisionSpec qualified as SupervisionSpec
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
            [ CommandSpec.tests,
              HealthWorkerSpec.tests,
              RunJobWorkerSpec.tests databaseFixture,
              SchedulerSpec.tests databaseFixture,
              StreamInboxSpec.tests databaseFixture,
              TimerRecoverySpec.tests databaseFixture,
              TelemetrySpec.tests,
              SupervisionSpec.tests
            ]
        )
