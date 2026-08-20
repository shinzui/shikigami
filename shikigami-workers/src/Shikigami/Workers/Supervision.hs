-- | What happens when a loop that was supposed to run forever stops.
--
-- == Why fail-fast, and not in-process restart
--
-- Shibuya offers no processor-level restart: its only two strategies are
-- @IgnoreFailures@ and @StopAllOnFailure@, and neither restarts a failed child.
-- Its retry story is per-message, not per-loop. So the choice is between writing
-- a supervisor here and letting the process die so that the /external/
-- supervisor — @process-compose@'s @restart: on_failure@, systemd's
-- @Restart=always@ — starts a clean one.
--
-- Fail-fast wins on both counts. It is less code, and an external supervisor
-- restarts a whole process better than a process can restart part of itself: an
-- in-process restarter has to decide which state the dead loop corrupted, and
-- the honest answer is usually \"unknown\". It also cannot mask a genuine fault
-- as an infinite restart loop, which is the failure mode that makes a
-- half-working deployment look healthy for days.
--
-- Bounded retry still belongs /inside/ a loop, for a transient dependency error
-- that a full cold restart would be a silly response to — see
-- "Shikigami.Agent.Workflow.Resume". The rule is: retry a dependency, exit on a
-- loop.
--
-- == Why a clean return is a failure
--
-- Every loop here is an infinite one, so returning normally is not success — it
-- is the loop having stopped for a reason it did not report. That is exactly the
-- shape of the two holes this module closes: @waitApp@ returning under
-- @IgnoreFailures@, where a stopped processor produces a clean return, and a
-- resume worker whose outer runner returned. Composing the loops with a bare
-- @concurrently_@ treats both as \"this branch finished, wait for the others\",
-- which is how a process ends up running three loops around a corpse.
module Shikigami.Workers.Supervision
  ( LoopExited (..),
    superviseLoops,
  )
where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Exception (Exception, throwIO)
import Data.Aeson qualified as Aeson
import Shikigami.Health.Worker (LoopName, loopCheckName)
import Shikigami.Log qualified as Log
import Shikigami.Prelude

-- | A loop stopped when it was supposed to run forever.
--
-- Carries which one, so the log line and the process's dying words name the
-- failure rather than leaving an operator to diff four loops' output.
newtype LoopExited = LoopExited LoopName
  deriving stock (Eq, Show)

instance Exception LoopExited

-- | Run every loop concurrently, and let any one of them ending stop the rest.
--
-- Both endings are covered. A loop that throws propagates out of
-- @mapConcurrently_@, which cancels its siblings. A loop that /returns/ is
-- converted into a 'LoopExited' throw first, so it takes the same path — without
-- that conversion, a returning loop would simply leave @mapConcurrently_@
-- waiting on the others forever with nothing doing its work.
--
-- The exception reaching the executable's @main@ is the point: the process exits
-- non-zero and the external supervisor starts a clean one.
superviseLoops :: Log.Logger -> [(LoopName, IO ())] -> IO ()
superviseLoops logger = mapConcurrently_ supervised
  where
    supervised (name, loop) = do
      loop
      Log.logError
        logger
        "worker.loop.exited"
        [ "loop" Aeson..= loopCheckName name,
          "reason" Aeson..= ("the loop returned; every loop in this process is expected to run until the process stops" :: Text)
        ]
      throwIO (LoopExited name)
