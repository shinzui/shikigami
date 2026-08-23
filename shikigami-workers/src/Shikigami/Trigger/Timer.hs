-- | Firing due timers.
--
-- Two things in the runtime wait on wall-clock time: a scheduled agent whose
-- cron expression has come round, and an approval that has been parked long
-- enough to time out. Both are recorded as Keiro /timers/ — rows carrying a fire
-- time and a payload — and both are fired by this one loop, because a timer
-- table with two independent readers would race.
--
-- Which of the two a given row is is decided by
-- 'Shikigami.Trigger.Scheduler.shikigamiTimerFallback': it tries to read the row
-- as a schedule payload first and falls back to the approval-timeout action.
module Shikigami.Trigger.Timer
  ( runTimerWorker,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Keiro.Workflow.Sleep (runWorkflowTimerWorker)
import Kioku.App (runAppIO)
import Shikigami.Health.Worker (LoopName (TimerLoop), beat)
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Trigger.Scheduler qualified as Scheduler
import Shikigami.Workers.Config (WorkerEnv (..), envHeartbeats, envKeiroMetrics, envLogger, schedulerEnv)

-- | Fire due timers until the process stops.
--
-- A store error is logged and the loop continues; the timer rows are durable, so
-- the next pass picks them up.
runTimerWorker :: WorkerEnv -> IO ()
runTimerWorker env = do
  Log.logInfo (envLogger env) "worker.timer.started" []
  forever do
    now <- getCurrentTime
    result <- runAppIO (appEnv env) (runWorkflowTimerWorker (envKeiroMetrics env) now (Scheduler.shikigamiTimerFallback (schedulerEnv env) now))
    case result of
      Left err -> Log.logError (envLogger env) "worker.timer.failed" ["error" Aeson..= Text.pack (show err)]
      Right _row -> pure ()
    -- Beat on every pass, failed included: see the outbox publisher for why a
    -- store error is not a wedge.
    beat (envHeartbeats env) TimerLoop
    threadDelay 1_000_000
