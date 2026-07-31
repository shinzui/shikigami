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
import Keiro.Workflow.Sleep (runWorkflowTimerWorker)
import Kioku.App (runAppIO)
import Shikigami.Prelude
import Shikigami.Trigger.Scheduler qualified as Scheduler
import Shikigami.Workers.Config (WorkerEnv (..), schedulerEnv)
import System.IO (hPutStrLn, stderr)

-- | Fire due timers until the process stops.
--
-- A store error is logged and the loop continues; the timer rows are durable, so
-- the next pass picks them up.
runTimerWorker :: WorkerEnv -> IO ()
runTimerWorker env = do
  hPutStrLn stderr "[shikigami.worker] starting keiro timer worker"
  forever do
    now <- getCurrentTime
    result <- runAppIO (appEnv env) (runWorkflowTimerWorker Nothing now (Scheduler.shikigamiTimerFallback (schedulerEnv env)))
    case result of
      Left err -> hPutStrLn stderr ("[shikigami.worker] timer worker store error: " <> show err)
      Right _row -> pure ()
    threadDelay 1_000_000
