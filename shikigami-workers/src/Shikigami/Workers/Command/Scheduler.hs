{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Shikigami.Workers.Command.Scheduler
  ( runSchedulerCmd,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, forever)
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Kioku.App (AppEnv (..), noopTracer)
import Kiroku.Store.Connection qualified as StoreConnection
import Kiroku.Store.Effect (Store, runStoreResource)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Loader (enabledAgentsFromReport, loadAgentsLoud)
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Log qualified as Log
import Shikigami.Trigger.Schedule (CronSchedule)
import Shikigami.Trigger.Scheduler (SchedulerEnv (..), armNextRun, runSchedulerTimerWorker)
import Shikigami.Workers.Config (schedulerSchedules)

-- | Arm every scheduled agent and drive keiro timer firing.
--
-- The manifest directory comes from @agents.directory@ (the @--agents@ flag is a
-- command-line source for it) and the connection string from
-- @database.connection_string@.
runSchedulerCmd :: AppConfig -> IO ()
runSchedulerCmd config = do
  logger <- Log.newStderrLogger Log.Info
  report <- loadAgentsLoud logger (Config.agentsDirectory config) (Config.agentsStrict config)
  agents <- enabledAgentsFromReport logger report
  -- The same resolution the worker's timer loop uses, so both processes report a
  -- bad cron the same way instead of one raising an ioError and the other
  -- dropping the agent in silence.
  scheduleMap <- schedulerSchedules logger (Config.agentsStrict config) agents
  let schedules = Map.toList scheduleMap
  Log.logInfo logger "scheduler.agents.loaded" ["count" Aeson..= length schedules]
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "shikigami-scheduler" config
  let settings = StoreConnection.defaultConnectionSettings connStr
  StoreConnection.withStore settings \st -> do
    tracer <- noopTracer
    let appEnv = AppEnv {connectionSettings = settings, tracer, metrics = Nothing}
        env =
          SchedulerEnv
            { pool = StoreConnection.pool st,
              schedules = scheduleMap,
              catchUpPolicy = Config.schedulerCatchUp config,
              logger
            }
    armAll logger appEnv schedules
    forever do
      now <- getCurrentTime
      result <- runStore appEnv (runSchedulerTimerWorker appEnv env now)
      case result of
        Left err -> Log.logError logger "scheduler.timer.failed" ["error" Aeson..= Text.pack (show err)]
        Right _ -> pure ()
      threadDelay 1_000_000

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
          ["agent" Aeson..= agentName, "error" Aeson..= Text.pack (show err)]
      Right () -> pure ()

runStore :: AppEnv -> Eff '[Store, KirokuStoreResource, Error StoreError, IOE] a -> IO (Either StoreError a)
runStore appEnv =
  runEff
    . runErrorNoCallStack @StoreError
    . withKirokuStore (connectionSettings appEnv)
    . runStoreResource
