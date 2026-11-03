{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Resuming durable workflows that stopped part-way.
--
-- A Keiro workflow can suspend — waiting for an approval, a timer, or a child —
-- and a process can crash mid-run. Neither case is a failure: the workflow's
-- journal records every step that already completed, and resuming replays that
-- journal and continues from the first step that did not.
--
-- The resume worker needs a /registry/: a map from workflow name to the code
-- that runs it. The shared registry includes agent runs, approval children,
-- conversations, execution drivers and continuing workers. Omitting any family
-- would leave its suspended instances without a progress owner.
module Shikigami.Agent.Workflow.Resume
  ( runResumeWorker,
    workflowRegistry,
    ResumeSummary (..),
    runBoundedResumeWorker,
    drainResumePasses,
    resumeSummaryFields,
    runWorkflowGc,
    terminalWorkflowRetention,

    -- * Restart policy
    ResumeRetry,
    mkResumeRetry,
    defaultResumeRetry,
    runResumeLoop,
    runResumeLoopWith,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Control.Lens ((&), (.~))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, diffUTCTime, getCurrentTime)
import GHC.TypeLits (Symbol)
import Keiro.Workflow.Gc (runWorkflowGcWorkerWith)
import Keiro.Workflow.Resume (ResumeSummary (..), WorkflowRegistry, resumeWorkflowsOnceUpTo, runWorkflowResumeWorkerWith)
import Shikigami.App (AppEffects, runAppIO)
import Shikigami.Duration
import Shikigami.Health.Supervision (LoopExited (LoopExited))
import Shikigami.Health.Worker (LoopName (ResumeLoop, WorkflowGcLoop))
import Shikigami.Log qualified as Log
import Shikigami.Workers.Config (WorkerEnv (..), agentRunDeps, conversationEnv, envLogger)
import Shikigami.Workflow.Registry qualified as Registry
import Shikigami.Workflow.Versioning (shikigamiWorkflowResumeOptionsWith, terminalWorkflowRetention)

-- | Every workflow this process knows how to resume.
workflowRegistry :: WorkerEnv -> WorkflowRegistry AppEffects
workflowRegistry env =
  Registry.workflowRegistry (agentRunDeps env) (conversationEnv env)

-- | How a returning resume runner is retried before the process gives up.
--
-- A record rather than four constants so a test can exercise the policy in
-- milliseconds instead of minutes.
data ResumeRetry = ResumeRetry
  { -- | Wait before the first retry.
    initialBackoffMicros :: !(BackoffMicros "initial"),
    -- | Ceiling the doubling backoff stops at.
    maxBackoffMicros :: !(BackoffMicros "maximum"),
    -- | How many consecutive short-lived runs before the process exits.
    failureCeiling :: !FailureCeiling,
    -- | How long a run must last to count as healthy and reset the tally.
    --
    -- Without this the tally only ever climbs, so a process with one blip an
    -- hour would exit after 'failureCeiling' hours of working correctly. What
    -- distinguishes a broken worker from an unlucky one is not how many times it
    -- restarted but whether it stays up in between.
    healthyRunSeconds :: !HealthyRunWindow
  }

type role BackoffMicros nominal

newtype BackoffMicros (scope :: Symbol) = BackoffMicros Int

newtype FailureCeiling = FailureCeiling Int

newtype HealthyRunWindow = HealthyRunWindow NominalDiffTime

-- | Zero delay or a zero healthy window are explicit immediate policies.
-- Negative values, a nonpositive failure ceiling and an initial delay above
-- the cap are refused before the loop can run or request a sleep.
mkResumeRetry :: Int -> Int -> Int -> NominalDiffTime -> Either Text ResumeRetry
mkResumeRetry initial maximumDelay ceilingCount healthyAfter
  | initial < 0 || maximumDelay < initial || ceilingCount < 1 || healthyAfter < 0 =
      Left "invalid resume restart policy"
  | otherwise =
      Right
        ResumeRetry
          { initialBackoffMicros = BackoffMicros initial,
            maxBackoffMicros = BackoffMicros maximumDelay,
            failureCeiling = FailureCeiling ceilingCount,
            healthyRunSeconds = HealthyRunWindow healthyAfter
          }

-- | One second, doubling to thirty; five consecutive short runs is fatal;
-- a run lasting a minute resets the tally. Retained workflow leases remain
-- independent: discovery skips leases that have not expired.
defaultResumeRetry :: ResumeRetry
defaultResumeRetry = either (error . Text.unpack) id (mkResumeRetry 1_000_000 30_000_000 5 60)

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
    result <- runAppIO ((.appEnv) env) (runWorkflowResumeWorkerWith (shikigamiWorkflowResumeOptionsWith env.capacity ((.appEnv) env) (durationTime runTimeout) & #logEvent .~ logResumeEvent (envLogger env)) (workflowRegistry env))
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
runResumeLoopWith sleep ResumeRetry {initialBackoffMicros = BackoffMicros initial, maxBackoffMicros = BackoffMicros maximumDelay, failureCeiling = FailureCeiling ceilingCount, healthyRunSeconds = HealthyRunWindow healthyAfter} logger runOnce = do
  Log.logInfo logger "worker.resume.started" []
  go 0 initial
  where
    go consecutiveFailures backoffMicros = do
      startedAt <- getCurrentTime
      reason <- runOnce
      endedAt <- getCurrentTime
      let lasted = diffUTCTime endedAt startedAt
          healthy = lasted >= healthyAfter
          failures = if healthy then 1 else consecutiveFailures + 1
          nextBackoff =
            if healthy
              then initial
              else fromInteger (min (toInteger maximumDelay) (toInteger backoffMicros * 2))
      Log.logError
        logger
        "worker.resume.failed"
        [ "error" .= reason,
          "ran_for_seconds" .= (realToFrac lasted :: Double),
          "consecutive_failures" .= failures
        ]
      if failures >= ceilingCount
        then do
          Log.logError
            logger
            "worker.resume.exhausted"
            ["consecutive_failures" .= failures, "ceiling" .= ceilingCount]
          throwIO (LoopExited ResumeLoop)
        else do
          sleep (if healthy then initial else backoffMicros)
          go failures nextBackoff

-- | Worker-owned operational action preserving the complete Kioku resource
-- effect row. Each pass has a candidate cap, and the drain has a pass cap.
-- A discovered but parked, paced, unknown or sleep-blocked row is not progress.
runBoundedResumeWorker :: Int -> Int -> WorkerEnv -> IO [ResumeSummary]
runBoundedResumeWorker passLimit candidateLimit env =
  drainResumePasses passLimit do
    let options =
          shikigamiWorkflowResumeOptionsWith env.capacity env.appEnv (durationTime env.runTimeout)
            & #logEvent .~ logResumeEvent (envLogger env)
    result <- runAppIO env.appEnv (resumeWorkflowsOnceUpTo candidateLimit options (workflowRegistry env))
    summary <- either throwIO pure result
    Log.logInfo (envLogger env) "worker.resume.pass" (resumeSummaryFields summary)
    pure summary

-- | A finite drain stops on zero durable progress, even when candidates remain.
drainResumePasses :: (Monad m) => Int -> m ResumeSummary -> m [ResumeSummary]
drainResumePasses limit pass
  | limit <= 0 = pure []
  | otherwise = do
      summary <- pass
      rest <- if summary.advanced > 0 then drainResumePasses (limit - 1) pass else pure []
      pure (summary : rest)

-- | Every released summary field is observable at the bounded boundary.
resumeSummaryFields :: ResumeSummary -> [Pair]
resumeSummaryFields summary =
  [ "discovered" .= summary.discovered,
    "advanced" .= summary.advanced,
    "resumed" .= summary.resumed,
    "completed" .= summary.completed,
    "still_suspended" .= summary.stillSuspended,
    "unknown_name" .= summary.unknownName,
    "failed" .= summary.failed,
    "transient_errors" .= summary.transientErrors,
    "lease_skipped" .= summary.leaseSkipped,
    "paced" .= summary.paced,
    "sleep_due" .= summary.sleepDue,
    "unregistered_names" .= summary.unregisteredNames
  ]

-- The process Logger writes each JSON line under the Handle lock, including
-- callbacks from concurrent upstream advances. Upstream supplies failures here;
-- successful continuous-pass summaries are not exposed by its released hook.
logResumeEvent :: (Show event) => Log.Logger -> event -> IO ()
logResumeEvent logger event = Log.logWarn logger "worker.resume.event" ["detail" .= show event]

runWorkflowGc :: WorkerEnv -> IO ()
runWorkflowGc env = do
  result <-
    runAppIO
      env.appEnv
      ( runWorkflowGcWorkerWith
          terminalWorkflowRetention
          3_600_000_000
          (\detail -> Log.logWarn (envLogger env) "worker.workflow_gc.failed" ["detail" .= detail])
      )
  either throwIO (const (throwIO (LoopExited WorkflowGcLoop))) result
