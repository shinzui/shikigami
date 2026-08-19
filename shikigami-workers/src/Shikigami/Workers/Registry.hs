-- | The worker process's composition root.
--
-- The @shikigami-worker@ executable runs four concurrent loops:
--
--   * the run-job queue processor, supervised by shibuya over pgmq;
--   * the Keiro workflow resume worker;
--   * the sink outbox publisher;
--   * the Keiro timer worker.
--
-- This module starts them and nothing else. Each loop's behavior lives in its
-- own vertical module, so that a change to how run jobs are acknowledged does
-- not touch the file that decides which loops exist.
--
-- All four run in one process because they share a database and are meaningless
-- apart: a resumed workflow enqueues sink intents that the outbox publisher must
-- deliver, and a fired timer enqueues run jobs the queue processor must drain.
-- Splitting them into separate deployments is a scaling decision for
-- @docs\/plans\/31-deployable-service-stack-process-compose-packaging-and-configuration.md@,
-- not a structural one.
module Shikigami.Workers.Registry
  ( runWorkers,
    runQueueWorker,
  )
where

import Control.Concurrent.Async (concurrently_)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Keiro.PGMQ (JobRuntime (..), defaultJobTuning, ensureJobQueue, jobProcessorWithContext, runJobEff, runJobWorkers)
import Kioku.App (AppEnv (..))
import Shibuya.App (SupervisionStrategy (IgnoreFailures), waitApp)
import Shikigami.Agent.RunJob.Worker (handleRunJob, runJob)
import Shikigami.Agent.Workflow.Resume (runResumeWorker)
import Shikigami.Flow.SinkOutbox.Publisher (runOutboxPublisher)
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Trigger.Timer (runTimerWorker)
import Shikigami.Workers.Config (WorkerEnv (..), envLogger)

-- | Start every worker loop and run until the process is stopped.
runWorkers :: WorkerEnv -> IO ()
runWorkers env = do
  Log.logInfo (envLogger env) "worker.loop.started" ["queue" Aeson..= ("shikigami_run_jobs" :: Text)]
  concurrently_
    (runQueueWorker env)
    (concurrently_ (runResumeWorker env) (concurrently_ (runOutboxPublisher env) (runTimerWorker env)))

-- | Drain @shikigami_run_jobs@ under shibuya's supervisor.
--
-- @IgnoreFailures@ keeps one poisoned message from taking the processor down;
-- the handler itself decides retry versus dead-letter per message.
runQueueWorker :: WorkerEnv -> IO ()
runQueueWorker env = do
  let runtime =
        JobRuntime
          { runtimePool = pool env,
            runtimeTracer = Just (tracer (appEnv env))
          }
  result <- runJobEff runtime do
    -- Queue reconciliation owns both the main queue and its policy-enabled DLQ.
    -- The worker does not start unless both are available.
    ensureJobQueue runJob
    liftIO $
      Log.logInfo
        (envLogger env)
        "worker.queue.reconciled"
        [ "queue" Aeson..= ("shikigami_run_jobs" :: Text),
          "dlq" Aeson..= ("shikigami_run_jobs_dlq" :: Text)
        ]
    appResult <-
      runJobWorkers
        IgnoreFailures
        100
        [jobProcessorWithContext defaultJobTuning runJob (handleRunJob env)]
    case appResult of
      Left err -> liftIO do
        Log.logError (envLogger env) "worker.loop.failed" ["error" Aeson..= Text.pack (show err)]
        ioError (userError ("run-job processor failed to start: " <> show err))
      Right app -> waitApp app
  case result of
    Left perr -> do
      Log.logError (envLogger env) "worker.queue.failed" ["error" Aeson..= Text.pack (show perr)]
      ioError (userError ("run-job queue reconciliation failed: " <> show perr))
    Right () -> pure ()
