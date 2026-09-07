-- | Resuming durable workflows that stopped part-way.
--
-- A Keiro workflow can suspend — waiting for an approval, a timer, or a child —
-- and a process can crash mid-run. Neither case is a failure: the workflow's
-- journal records every step that already completed, and resuming replays that
-- journal and continues from the first step that did not.
--
-- The resume worker needs a /registry/: a map from workflow name to the code
-- that runs it. Both workflow families are registered here — agent runs and
-- conversations — because a resume worker that knows only one of them would
-- silently leave the other suspended forever.
module Shikigami.Agent.Workflow.Resume
  ( runResumeWorker,
    workflowRegistry,

    -- * Restart policy
    ResumeRetry (..),
    defaultResumeRetry,
    runResumeLoop,
    runResumeLoopWith,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, diffUTCTime, getCurrentTime)
import Keiro.Workflow.Resume (WorkflowRegistry, runWorkflowResumeWorkerWith)
import Kioku.App (AppEffects, runAppIO)
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Health.Worker (LoopName (ResumeLoop))
import Shikigami.Log qualified as Log
import Shikigami.Workers.Config (WorkerEnv (..), agentRunDeps, conversationEnv, envLogger)
import Shikigami.Workers.Supervision (LoopExited (LoopExited))
import Shikigami.Workflow.Versioning (shikigamiWorkflowResumeOptions)

-- | Every workflow this process knows how to resume.
workflowRegistry :: WorkerEnv -> WorkflowRegistry AppEffects
workflowRegistry env =
  AgentWorkflow.agentRunRegistry (agentRunDeps env)
    `Map.union` Conversation.conversationRegistry (conversationEnv env)

-- | How a returning resume runner is retried before the process gives up.
--
-- A record rather than four constants so a test can exercise the policy in
-- milliseconds instead of minutes.
data ResumeRetry = ResumeRetry
  { -- | Wait before the first retry.
    initialBackoffMicros :: !Int,
    -- | Ceiling the doubling backoff stops at.
    maxBackoffMicros :: !Int,
    -- | How many consecutive short-lived runs before the process exits.
    failureCeiling :: !Int,
    -- | How long a run must last to count as healthy and reset the tally.
    --
    -- Without this the tally only ever climbs, so a process with one blip an
    -- hour would exit after 'failureCeiling' hours of working correctly. What
    -- distinguishes a broken worker from an unlucky one is not how many times it
    -- restarted but whether it stays up in between.
    healthyRunSeconds :: !NominalDiffTime
  }

-- | One second, doubling to thirty; five consecutive short runs is fatal; a run
-- lasting a minute counts as healthy.
--
-- The backoff is deliberately not raised to cover the resume lease TTL
-- ('Shikigami.Workflow.Versioning.shikigamiWorkflowResumeOptions' sizes it above
-- the behavior timeout). A fresh runner does not contend with leases the
-- previous one held: keiro's discovery skips instances whose lease has not
-- expired, so an early retry finds less work rather than the same work twice.
defaultResumeRetry :: ResumeRetry
defaultResumeRetry =
  ResumeRetry
    { initialBackoffMicros = 1_000_000,
      maxBackoffMicros = 30_000_000,
      failureCeiling = 5,
      healthyRunSeconds = 60
    }

-- | Run the resume loop until the process stops.
--
-- == What was actually broken here
--
-- This function used to call the runner once and return, and the plan that
-- produced this change described that as \"no suspended workflow is ever resumed
-- again\" for any store error. That overstates it:
-- @runWorkflowResumeWorkerWith@ is itself a @forever@ loop that catches a
-- @StoreError@ or a synchronous exception /per pass/ and keeps going, so a
-- transient database blip never reached this code at all.
--
-- What does reach it is a failure of the runner as a whole — the store resource
-- failing to acquire, say — which returns @Left@ from 'runAppIO'. That case was
-- real and was exactly as bad as advertised: one log line, a return, and a
-- process that went on running its other three loops with nothing resuming
-- workflows. A @Right@ return is equally wrong for the same reason, since a
-- @forever@ loop returning normally means something ended it.
--
-- So both outcomes are treated as the runner having stopped, and the loop
-- restarts it with capped backoff. A persistent failure trips the ceiling and
-- exits, which hands the problem to the external supervisor rather than spinning
-- here forever.
--
-- == Why this loop has no heartbeat
--
-- The other three loops beat once per pass. This one cannot: its passes happen
-- inside keiro's @forever@, and @ResumeLogEvent@ has no per-pass success event
-- to hook — only failures — so there is nothing to beat on while it is working
-- normally. Registering it with a staleness bound would fail liveness on a
-- perfectly healthy loop. Its coverage comes from fail-fast instead: the only
-- way this loop can stop is by returning, and returning now exits the process.
runResumeWorker :: WorkerEnv -> IO ()
runResumeWorker env@WorkerEnv {runTimeout} =
  runResumeLoop defaultResumeRetry (envLogger env) do
    result <- runAppIO ((.appEnv) env) (runWorkflowResumeWorkerWith (shikigamiWorkflowResumeOptions ((.appEnv) env) runTimeout) (workflowRegistry env))
    pure case result of
      Left err -> Text.pack (show err)
      Right () -> "the resume runner returned without an error, which a forever loop should never do"

-- | The restart policy, over an action that runs the resume runner until it
-- stops and says why.
--
-- Separated from 'runResumeWorker' so the policy can be tested without a
-- database: everything worth getting wrong — when it retries, how long it waits,
-- what resets the tally, when it gives up — is here.
runResumeLoop :: ResumeRetry -> Log.Logger -> IO Text -> IO ()
runResumeLoop = runResumeLoopWith threadDelay

-- | 'runResumeLoop' with the sleeper supplied.
--
-- Exposed so a test can assert the exact delays this loop asks for rather than
-- measuring how long it actually slept. A wall-clock measurement of a backoff
-- can only prove a lower bound reliably — @threadDelay@ never undersleeps but
-- may oversleep by any amount on a loaded machine — which is precisely the wrong
-- half for proving a /cap/ holds.
runResumeLoopWith :: (Int -> IO ()) -> ResumeRetry -> Log.Logger -> IO Text -> IO ()
runResumeLoopWith sleep retry logger runOnce = do
  Log.logInfo logger "worker.resume.started" []
  go 0 ((.initialBackoffMicros) retry)
  where
    go consecutiveFailures backoffMicros = do
      startedAt <- getCurrentTime
      reason <- runOnce
      endedAt <- getCurrentTime
      let lasted = diffUTCTime endedAt startedAt
          healthy = lasted >= (.healthyRunSeconds) retry
          failures = if healthy then 1 else consecutiveFailures + 1
          nextBackoff =
            if healthy
              then (.initialBackoffMicros) retry
              else min ((.maxBackoffMicros) retry) (backoffMicros * 2)
      Log.logError
        logger
        "worker.resume.failed"
        [ "error" Aeson..= reason,
          "ran_for_seconds" Aeson..= (realToFrac lasted :: Double),
          "consecutive_failures" Aeson..= failures
        ]
      if failures >= (.failureCeiling) retry
        then do
          Log.logError
            logger
            "worker.resume.exhausted"
            ["consecutive_failures" Aeson..= failures, "ceiling" Aeson..= (.failureCeiling) retry]
          throwIO (LoopExited ResumeLoop)
        else do
          sleep (if healthy then (.initialBackoffMicros) retry else backoffMicros)
          go failures nextBackoff
