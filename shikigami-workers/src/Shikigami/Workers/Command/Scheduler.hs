{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Shikigami.Workers.Command.Scheduler
  ( runSchedulerCmd,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, forever)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Effectful (Eff)
import Kiroku.Store.Connection qualified as StoreConnection
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Loader (enabledAgentsFromReport, loadAgentsLoud)
import Shikigami.App (AppEffects, AppEnv (..), runAppIO)
import Shikigami.App.Config (AppConfig, Role (SchedulerRole))
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Directory (DirectoryRuntime (..))
import Shikigami.Health.Worker (LoopName (DirectoryLoop, SchedulerLoop), beat, loopStaleAfter, newHeartbeatsWithStaleness, serveProbesWith)
import Shikigami.Inspection.Runtime (withInspectionRuntime)
import Shikigami.Inspection.Store (withObservedStore)
import Shikigami.Log qualified as Log
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Runtime (registerRuntimeCatalog, runtimeConnectionSettings)
import Shikigami.Telemetry (withRunTelemetry)
import Shikigami.Trigger.Enqueue (ensureRunQueue)
import Shikigami.Trigger.Schedule (CronSchedule)
import Shikigami.Trigger.Scheduler (SchedulerEnv (..), armNextRun, runSchedulerTimerWorker)
import Shikigami.Workers.Config (directoryLoopRegistration, persistAgentLoadReport, principalIdsByAgent, schedulerSchedules, startProcessDirectory)
import Shikigami.Workers.Supervision (superviseLoops)
import System.Exit (exitFailure)

-- | Arm every scheduled agent and drive keiro timer firing.
--
-- The manifest directory comes from @agents.directory@ (the @--agents@ flag is a
-- command-line source for it) and the connection string from
-- @database.connection_string@.
runSchedulerCmd :: AppConfig -> IO ()
runSchedulerCmd config = do
  logger <- Log.newStderrLogger Log.Info
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "shikigami-scheduler" config
  verifyShikigamiMigrations connStr
  withRunTelemetry "shikigami.scheduler" \tr keiroMetrics _ -> do
    let settings = runtimeConnectionSettings logger keiroMetrics connStr
    withObservedStore tr settings \st storeMetrics -> do
      registerRuntimeCatalog st
      withInspectionRuntime config.inspection logger settings st storeMetrics [] \_ -> do
        let manifestDirectory = (.agentsDirectory) config
            storePool = StoreConnection.pool st
        report <-
          loadAgentsLoud
            logger
            manifestDirectory
            ((.agentsStrict) config)
            (persistAgentLoadReport logger storePool manifestDirectory)
        agents <- enabledAgentsFromReport logger report
        -- The same resolution the worker's timer loop uses, so both processes
        -- report a bad cron the same way instead of one raising an ioError and the
        -- other dropping the agent in silence.
        scheduleMap <- schedulerSchedules logger ((.agentsStrict) config) agents
        let schedules = Map.toList scheduleMap
        Log.logInfo logger "scheduler.agents.loaded" ["count" .= length schedules]
        -- The other startup path that used to rely on the per-send createQueue
        -- inside enqueueRunJob. A timer that fires into a queue that does not exist
        -- is a run that never happens.
        queueResult <- ensureRunQueue storePool
        case queueResult of
          Left err -> do
            Log.logError logger "scheduler.queue.failed" ["error" .= Text.pack (show err)]
            exitFailure
          Right () ->
            Log.logInfo logger "scheduler.queue.reconciled" ["queue" .= ("shikigami_run_jobs" :: Text)]
        registry <-
          newHeartbeatsWithStaleness
            ( (SchedulerLoop, loopStaleAfter SchedulerLoop)
                : directoryLoopRegistration ((.directorySettings) config)
            )
        DirectoryRuntime {handle = directory, refresher = directoryRefresher} <-
          startProcessDirectory logger registry ((.directorySettings) config)
        let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = keiroMetrics, store = Just st}
            env =
              SchedulerEnv
                { pool = storePool,
                  schedules = scheduleMap,
                  principalIds = principalIdsByAgent agents,
                  directory,
                  catchUpPolicy = (.schedulerCatchUp) config,
                  logger
                }
        armAll logger appEnv schedules
        let schedulerLoop = forever do
              now <- getCurrentTime
              result <- runStore appEnv (runSchedulerTimerWorker appEnv env now)
              case result of
                Left err -> Log.logError logger "scheduler.timer.failed" ["error" .= Text.pack (show err)]
                Right _ -> pure ()
              -- Beat on every pass, failed included: a store error is a dependency
              -- being unavailable, not this loop being wedged.
              beat registry SchedulerLoop
              threadDelay 1_000_000
            directoryLoops = maybe [] (pure . (DirectoryLoop,)) directoryRefresher
        serveProbesWith
          logger
          ((.httpHost) config)
          (Config.healthPortFor SchedulerRole config)
          storePool
          registry
          (superviseLoops logger ((SchedulerLoop, schedulerLoop) : directoryLoops))

armAll :: Log.Logger -> AppEnv -> [(Text, CronSchedule)] -> IO ()
armAll logger appEnv schedules =
  forM_ schedules \(agentName, cron) -> do
    now <- getCurrentTime
    result <- runStore appEnv (armNextRun cron agentName now)
    case result of
      Left err ->
        Log.logError
          logger
          "scheduler.agent.arm_failed"
          ["agent" .= agentName, "error" .= Text.pack (show err)]
      Right () -> pure ()

runStore :: AppEnv -> Eff AppEffects a -> IO (Either StoreError a)
runStore = runAppIO
