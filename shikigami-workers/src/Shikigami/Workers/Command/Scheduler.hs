{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Shikigami.Workers.Command.Scheduler
  ( runSchedulerCmd,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, forever)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Kioku.App (AppEnv (..), noopTracer)
import Kiroku.Store.Connection qualified as StoreConnection
import Kiroku.Store.Effect (Store, runStorePool)
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Decl (AgentDecl (..), Trigger (..))
import Shikigami.Agent.Loader (loadAgentsIn)
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Trigger.Schedule (CronSchedule, parseCron)
import Shikigami.Trigger.Scheduler (SchedulerEnv (..), armNextRun, runSchedulerTimerWorker)
import System.IO (hPutStrLn, stderr)

-- | Arm every scheduled agent and drive keiro timer firing.
--
-- The manifest directory comes from @agents.directory@ (the @--agents@ flag is a
-- command-line source for it) and the connection string from
-- @database.connection_string@.
runSchedulerCmd :: AppConfig -> IO ()
runSchedulerCmd config = do
  agents <- loadAgentsIn (Config.agentsDirectory config)
  schedules <- traverse parseScheduleAgent (filter isSchedule agents)
  putStrLn ("[scheduler] loaded " <> show (length schedules) <> " scheduled agents")
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "shikigami-scheduler" config
  StoreConnection.withStore (StoreConnection.defaultConnectionSettings connStr) \st -> do
    tracer <- noopTracer
    let appEnv = AppEnv {store = st, tracer, metrics = Nothing}
        env = SchedulerEnv {pool = StoreConnection.pool st, schedules = Map.fromList schedules}
    armAll appEnv schedules
    forever do
      now <- getCurrentTime
      result <- runStore appEnv (runSchedulerTimerWorker appEnv env now)
      case result of
        Left err -> hPutStrLn stderr ("[scheduler] timer worker store error: " <> show err)
        Right _ -> pure ()
      threadDelay 1_000_000

armAll :: AppEnv -> [(Text, CronSchedule)] -> IO ()
armAll appEnv schedules =
  forM_ schedules \(agentName, cron) -> do
    now <- getCurrentTime
    result <- runStore appEnv (armNextRun cron agentName now)
    case result of
      Left err -> hPutStrLn stderr ("[scheduler] failed to arm " <> Text.unpack agentName <> ": " <> show err)
      Right () -> pure ()

parseScheduleAgent :: AgentDecl -> IO (Text, CronSchedule)
parseScheduleAgent AgentDecl {name, trigger = Schedule {cron}} =
  case parseCron cron of
    Right parsed -> pure (name, parsed)
    Left err -> ioError (userError ("invalid cron for " <> Text.unpack name <> ": " <> Text.unpack err))
parseScheduleAgent AgentDecl {name} =
  ioError (userError ("agent is not scheduled: " <> Text.unpack name))

isSchedule :: AgentDecl -> Bool
isSchedule AgentDecl {trigger = Schedule {}} = True
isSchedule _ = False

runStore :: AppEnv -> Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)
runStore appEnv =
  runEff
    . runErrorNoCallStack @StoreError
    . runStorePool (store appEnv)
