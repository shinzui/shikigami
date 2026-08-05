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
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Kioku.App (AppEnv (..))
import Pgmq.Effectful.Interpreter (PgmqRuntimeError, runPgmq)
import Shibuya.Adapter.Pgmq (pgmqAdapter)
import Shibuya.Adapter.Pgmq.Config (defaultConfig, mkPgmqAdapterEnv)
import Shibuya.App (AppConfig (..), ProcessorId (..), SupervisionStrategy (IgnoreFailures), mkProcessor, runApp, waitApp)
import Shibuya.Telemetry.Effect (runTracing)
import Shikigami.Agent.RunJob.Worker (runJobHandler)
import Shikigami.Agent.Workflow.Resume (runResumeWorker)
import Shikigami.Flow.SinkOutbox.Publisher (runOutboxPublisher)
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Trigger.Enqueue (runQueueName)
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
  result <-
    runEff . runErrorNoCallStack @PgmqRuntimeError . runPgmq (pool env) . runTracing (tracer (appEnv env)) $ do
      -- shibuya-pgmq-adapter 0.12 splits the adapter's runtime environment
      -- (pool plus dead-letter/ack-failure callbacks) from its queue
      -- configuration, and validates the latter before constructing anything.
      adapterResult <- pgmqAdapter (mkPgmqAdapterEnv (pool env)) (defaultConfig runQueueName)
      case adapterResult of
        Left cfgErr ->
          liftIO (Log.logError (envLogger env) "worker.queue.misconfigured" ["error" Aeson..= Text.pack (show cfgErr)])
        Right adapter -> do
          let processor = mkProcessor adapter (runJobHandler env)
          appResult <-
            runApp
              AppConfig {strategy = IgnoreFailures, inboxSize = 100}
              [(ProcessorId "shikigami_run_jobs", processor)]
          case appResult of
            Left err -> liftIO (Log.logError (envLogger env) "worker.loop.failed" ["error" Aeson..= Text.pack (show err)])
            Right h -> waitApp h
  case result of
    Left perr -> Log.logError (envLogger env) "worker.queue.failed" ["error" Aeson..= Text.pack (show perr)]
    Right () -> pure ()
