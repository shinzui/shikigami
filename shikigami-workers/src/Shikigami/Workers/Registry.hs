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

import Control.Exception (throwIO)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Keiro.PGMQ (Job (..), JobRuntime (..), defaultJobTuning, ensureJobQueue, jobProcessorWithContext, runJobEff, runJobWorkers)
import Kioku.App (AppEnv (..))
import Shibuya.App (ProcessorId (ProcessorId), SupervisionStrategy (IgnoreFailures), getAppMaster, getAppMetrics, waitApp)
import Shikigami.Agent.RunJob.Worker (handleRunJob, runJob)
import Shikigami.Agent.Workflow.Resume (runResumeWorker)
import Shikigami.Flow.SinkOutbox.Publisher (runOutboxPublisher)
import Shikigami.Health.Worker (LoopName (OutboxLoop, QueueLoop, ResumeLoop, TimerLoop), registerReport, supervisedLoopVerdict)
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Trigger.Timer (runTimerWorker)
import Shikigami.Workers.Config (WorkerEnv (..), envHeartbeats, envLogger)
import Shikigami.Workers.Supervision (LoopExited (LoopExited), superviseLoops)

-- | Start every worker loop and run until the process is stopped.
--
-- 'superviseLoops' rather than nested @concurrently_@: all four are infinite
-- loops, so any one of them ending — by throwing /or/ by returning — must take
-- the process down. Nested @concurrently_@ propagates the first but treats the
-- second as a branch that finished, which is how this process used to end up
-- running three loops around a corpse.
runWorkers :: WorkerEnv -> IO ()
runWorkers env = do
  Log.logInfo (envLogger env) "worker.loop.started" ["queue" Aeson..= jobName runJob]
  superviseLoops
    (envLogger env)
    [ (QueueLoop, runQueueWorker env),
      (ResumeLoop, runResumeWorker env),
      (OutboxLoop, runOutboxPublisher env),
      (TimerLoop, runTimerWorker env)
    ]

-- | The id shibuya knows the run-job processor by.
--
-- Derived from 'runJob' rather than spelled out, because @jobProcessorWithContext@
-- registers the processor under @ProcessorId job.jobName@ and the liveness probe
-- looks it up by that id. Repeating the literal here would let the two drift,
-- and the symptom would be a probe reporting the queue loop as missing while it
-- ran perfectly.
queueProcessorId :: ProcessorId
queueProcessorId = ProcessorId (jobName runJob)

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
      Right app -> do
        -- This loop reports its liveness through shibuya rather than beating,
        -- because shibuya already tracks what the processor actually did. The
        -- master is available only once the supervisor is running, which is why
        -- the registry is filled here rather than at boot.
        liftIO (registerReport (envHeartbeats env) QueueLoop (supervisedLoopVerdict QueueLoop (getAppMaster app) queueProcessorId))
        waitApp app
        -- Reaching here means the supervisor stopped. Under @IgnoreFailures@ a
        -- processor that died takes its supervisor with it without raising
        -- anything, so this is a silent death and not a clean shutdown. Report
        -- what each processor was doing before throwing: which one stopped, and
        -- in what state, is the one line an operator will want.
        metrics <- getAppMetrics app
        liftIO do
          -- The whole metrics map, keyed by processor id: which processor
          -- stopped, in what state, and with what counters behind it. Shibuya's
          -- own codecs render it, so this line cannot drift from the states the
          -- probe reads.
          Log.logError (envLogger env) "worker.queue.stopped" ["processors" Aeson..= metrics]
          throwIO (LoopExited QueueLoop)
  case result of
    Left perr -> do
      Log.logError (envLogger env) "worker.queue.failed" ["error" Aeson..= Text.pack (show perr)]
      ioError (userError ("run-job queue reconciliation failed: " <> show perr))
    Right () -> pure ()
