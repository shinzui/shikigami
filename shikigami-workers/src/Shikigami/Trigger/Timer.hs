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
  ( runTimerPass,
    runTimerWorker,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Keiro.Telemetry (KeiroMetrics)
import Keiro.Workflow.Sleep (drainWorkflowSleepTimers)
import Kiroku.Store.Error (StoreError)
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Health.Worker (LoopName (TimerLoop), beat)
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Trigger.Scheduler qualified as Scheduler
import Shikigami.Workers.Config (WorkerEnv (..), envHeartbeats, envKeiroMetrics, envLogger, schedulerEnv)

-- | Run the exact bounded maintenance and dispatch pass used by the serving
-- loop. Keeping this finite boundary public lets operator and integration tests
-- prove claim recovery without starting an immortal worker thread.
runTimerPass :: AppEnv -> Maybe KeiroMetrics -> Scheduler.SchedulerEnv -> UTCTime -> IO (Either StoreError Int)
runTimerPass appEnv metrics scheduler now =
  runAppIO appEnv (drainWorkflowSleepTimers metrics now 100 (Scheduler.shikigamiTimerFallback scheduler now))

-- | Fire due timers until the process stops.
--
-- A store error is logged and the loop continues; the timer rows are durable, so
-- the next pass picks them up.
runTimerWorker :: WorkerEnv -> IO ()
runTimerWorker env = do
  Log.logInfo (envLogger env) "worker.timer.started" []
  forever do
    now <- getCurrentTime
    result <- runTimerPass ((.appEnv) env) (envKeiroMetrics env) (schedulerEnv env) now
    case result of
      Left err -> Log.logError (envLogger env) "worker.timer.failed" ["error" Aeson..= Text.pack (show err)]
      Right count -> Log.logDebug (envLogger env) "worker.timer.pass" ["fired" Aeson..= count]
    -- Beat on every pass, failed included: see the outbox publisher for why a
    -- store error is not a wedge.
    beat (envHeartbeats env) TimerLoop
    threadDelay 1_000_000
