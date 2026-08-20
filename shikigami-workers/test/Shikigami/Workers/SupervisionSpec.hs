-- | A dead loop takes the process down, and a transient one does not.
--
-- These are the two halves of the supervision decision, and both are testable
-- without a database because both were deliberately built as policy over an
-- injected action rather than as behavior tangled into a loop body. That is also
-- why there is no fault-injection hook in @WorkerEnv@: a private test flag on a
-- production record is a worse seam than a function that takes the action it
-- supervises.
module Shikigami.Workers.SupervisionSpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Control.Exception (Exception, throwIO, try)
import Control.Monad (forever, void)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Shikigami.Agent.Workflow.Resume (ResumeRetry (..), runResumeLoop, runResumeLoopWith)
import Shikigami.Health.Worker (LoopName (OutboxLoop, ResumeLoop, TimerLoop))
import Shikigami.Log qualified as Log
import Shikigami.Workers.Supervision (LoopExited (LoopExited), superviseLoops)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "loop supervision"
    [ superviseTests,
      resumeRetryTests
    ]

superviseTests :: TestTree
superviseTests =
  testGroup
    "superviseLoops"
    [ -- The hole this replaced nested concurrently_ to close. A loop that
      -- returns is not a branch that finished successfully; it is an infinite
      -- loop that stopped, and the other three must not go on without it.
      testCase "a loop that returns cleanly stops the process, naming itself" do
        logger <- pure Log.silentLogger
        siblingRan <- newIORef (0 :: Int)
        outcome <-
          try @LoopExited $
            superviseLoops
              logger
              [ (OutboxLoop, pure ()),
                (TimerLoop, forever (atomicModifyIORef' siblingRan (\n -> (n + 1, ())) >> threadDelay 1_000))
              ]
        case outcome of
          Right () -> assertFailure "expected the returning loop to stop the process"
          Left (LoopExited name) -> name @?= OutboxLoop,
      testCase "a loop that throws propagates its own exception" do
        outcome <-
          try @Boom $
            superviseLoops
              Log.silentLogger
              [ (OutboxLoop, throwIO Boom),
                (TimerLoop, forever (threadDelay 1_000))
              ]
        case outcome of
          Right () -> assertFailure "expected the thrown exception to escape"
          Left Boom -> pure (),
      -- Siblings must actually be cancelled rather than left running detached,
      -- or a "dead" process keeps writing to the database after its supervisor
      -- has already decided to restart it.
      testCase "a dying loop cancels its siblings" do
        stillRunning <- newMVar (0 :: Int)
        void $
          try @LoopExited $
            superviseLoops
              Log.silentLogger
              [ (OutboxLoop, threadDelay 50_000),
                (TimerLoop, forever (bump stillRunning >> threadDelay 5_000))
              ]
        afterExit <- readMVar stillRunning
        threadDelay 100_000
        afterWaiting <- readMVar stillRunning
        assertBool
          ( "the sibling kept running after supervision ended: "
              <> show afterExit
              <> " then "
              <> show afterWaiting
          )
          (afterExit == afterWaiting),
      -- Every loop runs, rather than the list being traversed sequentially.
      testCase "all loops run concurrently" do
        started <- newMVar (0 :: Int)
        void $
          try @LoopExited $
            superviseLoops
              Log.silentLogger
              [ (OutboxLoop, bump started >> threadDelay 50_000),
                (TimerLoop, bump started >> threadDelay 50_000),
                (ResumeLoop, bump started >> threadDelay 50_000)
              ]
        readMVar started >>= (@?= 3)
    ]

resumeRetryTests :: TestTree
resumeRetryTests =
  testGroup
    "resume restart policy"
    [ -- The behavior the old code lacked entirely: it returned on the first
      -- failure and never ran again.
      testCase "a returning runner is retried rather than abandoned" do
        attempts <- newIORef (0 :: Int)
        outcome <-
          try @LoopExited $
            runResumeLoopWith
              (\_ -> pure ())
              (fastRetry 4)
              Log.silentLogger
              (atomicModifyIORef' attempts (\n -> (n + 1, ())) >> pure "store unavailable")
        case outcome of
          Right () -> assertFailure "expected the ceiling to be reached"
          Left (LoopExited name) -> name @?= ResumeLoop
        readIORef attempts >>= (@?= 4),
      testCase "exhausting the ceiling exits, naming the resume loop" do
        outcome <- try @LoopExited (runResumeLoopWith (\_ -> pure ()) (fastRetry 2) Log.silentLogger (pure "still broken"))
        case outcome of
          Right () -> assertFailure "expected the ceiling to be reached"
          Left (LoopExited name) -> name @?= ResumeLoop,
      -- What separates a broken worker from an unlucky one is whether it stays
      -- up in between. A run that lasted long enough resets the tally, so a
      -- process with an occasional blip is not eventually killed by arithmetic.
      testCase "a run that lasted resets the failure tally" do
        attempts <- newIORef (0 :: Int)
        -- Every run counts as healthy, so the tally never climbs past one and
        -- the ceiling of two is never reached. Bounded by the attempt count
        -- rather than by the ceiling, so a broken reset shows up as this test
        -- hanging into its own timeout rather than passing.
        outcome <-
          try @Boom $
            try @LoopExited $
              runResumeLoopWith
                (\_ -> pure ())
                (fastRetry 2) {healthyRunSeconds = 0}
                Log.silentLogger
                do
                  count <- atomicModifyIORef' attempts (\n -> (n + 1, n + 1))
                  if count >= 6 then throwIO Boom else pure "restarted"
        case outcome of
          Left Boom -> pure ()
          Right (Left (LoopExited _)) ->
            assertFailure "a healthy run should have reset the tally, but the ceiling was reached"
          Right (Right ()) -> assertFailure "expected the injected stop"
        readIORef attempts >>= (@?= 6),
      -- The delays the loop asks for, not the delays the machine delivered.
      -- Measuring elapsed time can only prove a lower bound reliably --
      -- threadDelay never undersleeps but may oversleep by any amount under
      -- load -- and a cap needs the upper half.
      testCase "the wait doubles between attempts and then stops at the cap" do
        requested <- newIORef []
        let retry = (fastRetry 6) {initialBackoffMicros = 1_000, maxBackoffMicros = 4_000}
        _ <-
          try @LoopExited $
            runResumeLoopWith
              (\micros -> atomicModifyIORef' requested (\waits -> (micros : waits, ())))
              retry
              Log.silentLogger
              (pure "still broken")
        waits <- reverse <$> readIORef requested
        -- Five waits before the sixth failure trips the ceiling. The cap holds
        -- at 4000 instead of the doubling running on to 8000 and 16000.
        waits @?= [1_000, 2_000, 4_000, 4_000, 4_000]
    ]

-- ── Helpers ─────────────────────────────────────────────────────────────────

-- | A policy with the same shape as production and delays a test can wait out.
fastRetry :: Int -> ResumeRetry
fastRetry ceilingCount =
  ResumeRetry
    { initialBackoffMicros = 1_000,
      maxBackoffMicros = 4_000,
      failureCeiling = ceilingCount,
      healthyRunSeconds = 3600
    }

bump :: MVar Int -> IO ()
bump cell = modifyMVar cell (\n -> pure (n + 1, ()))

-- | A synchronous exception distinguishable from 'LoopExited'.
data Boom = Boom
  deriving stock (Eq, Show)

instance Exception Boom
