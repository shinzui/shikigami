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
    queueTuningFor,
  )
where

import Control.Exception (throwIO)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Int (Int32)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Keiro.PGMQ (Job (..), JobPolling (PollEvery), JobRuntime (..), JobTuning, ensureJobQueueWith, jobProcessorWithContext, mkJobTuning, runJobEff, runJobWorkers)
import Shibuya.App (ProcessorId (ProcessorId), SupervisionStrategy (StopAllOnFailure), getAppMaster, getAppMetrics, waitApp)
import Shibuya.App qualified as Processor
import Shibuya.Policy (Concurrency (Async, Serial))
import Shikigami.Agent.RunJob.Worker (handleRunJob, runJob)
import Shikigami.Agent.Workflow.Resume (runResumeWorker, runWorkflowGc)
import Shikigami.App (AppEnv (..))
import Shikigami.Duration
import Shikigami.Execution.Capacity qualified as Capacity
import Shikigami.Flow.SinkOutbox.Publisher (runOutboxPublisher)
import Shikigami.Health.Supervision (LoopExited (LoopExited), superviseLoops)
import Shikigami.Health.Worker (LoopName (DirectoryLoop, ObjectiveTrackerLoop, OutboxLoop, QueueLoop, ResumeLoop, TelemetryLoop, TimerLoop, WorkflowGcLoop), loopStaleness, registerReport, supervisedLoopVerdictWithStaleness)
import Shikigami.Inspection.Consumer (withConsumerInspection)
import Shikigami.Integration.ConsumerRuntime (withConsumerAppAcquisition)
import Shikigami.Log qualified as Log
import Shikigami.Objective.Tracker.Worker (runTrackerWorker)
import Shikigami.Prelude hiding ((.=))
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Telemetry.Sampler (runTelemetrySampler)
import Shikigami.Trigger.Timer (runTimerWorker)
import Shikigami.Workers.Config (WorkerEnv (..), envDirectoryRefresher, envHeartbeats, envLogger)

-- | Start every worker loop and run until the process is stopped.
--
-- 'superviseLoops' rather than nested @concurrently_@: all four are infinite
-- loops, so any one of them ending — by throwing /or/ by returning — must take
-- the process down. Nested @concurrently_@ propagates the first but treats the
-- second as a branch that finished, which is how this process used to end up
-- running three loops around a corpse.
runWorkers :: WorkerEnv -> IO ()
runWorkers env = do
  Log.logInfo (envLogger env) "worker.loop.started" ["queue" .= jobName runJob]
  let durableLoops =
        [ (QueueLoop, runQueueWorker env),
          (ResumeLoop, runResumeWorker env),
          (WorkflowGcLoop, runWorkflowGc env),
          (OutboxLoop, runOutboxPublisher env),
          (TimerLoop, runTimerWorker env),
          (TelemetryLoop, runTelemetrySampler env)
        ]
      directoryLoops = maybe [] (pure . (DirectoryLoop,)) (envDirectoryRefresher env)
  superviseLoops (envLogger env) (durableLoops <> directoryLoops <> maybe [] (\host -> [(ObjectiveTrackerLoop, runTrackerWorker env host)]) env.trackers)

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
-- The handler decides retry versus dead-letter per message. Infrastructure or
-- finalization failure stops the application and reaches process supervision.
runQueueWorker :: WorkerEnv -> IO ()
runQueueWorker env = do
  tuning <- either (ioError . userError . Text.unpack) pure (queueTuningFor (durationTime env.runTimeout))
  let runtime =
        JobRuntime
          { runtimePool = (.pool) env,
            runtimeTracer = Just (env.appEnv.tracer)
          }
  result <- runJobEff runtime do
    -- Queue reconciliation owns both the main queue and its policy-enabled DLQ.
    -- The worker does not start unless both are available.
    ensureJobQueueWith RunJobs.queueProvision runJob
    liftIO $
      Log.logInfo
        (envLogger env)
        "worker.queue.reconciled"
        [ "queue" .= ("shikigami_run_jobs" :: Text),
          "dlq" .= ("shikigami_run_jobs_dlq" :: Text)
        ]
    appResult <-
      withConsumerAppAcquisition
        ( runJobWorkers
            StopAllOnFailure
            1
            [fmap (\(key, processor) -> (key, processor {Processor.concurrency = if Capacity.capacityLimit env.capacity.execution == 1 then Serial else Async (Capacity.capacityLimit env.capacity.execution)})) (jobProcessorWithContext tuning runJob (handleRunJob env))]
        )
        \app -> withConsumerInspection env.inspection (getAppMaster app) do
          -- This loop reports its liveness through shibuya rather than beating,
          -- because shibuya already tracks what the processor actually did. The
          -- master is available only once the supervisor is running, which is why
          -- the registry is filled here rather than at boot.
          liftIO (registerReport (envHeartbeats env) QueueLoop (supervisedLoopVerdictWithStaleness (loopStaleness (durationTime env.runTimeout + 30)) QueueLoop (getAppMaster app) queueProcessorId))
          waitApp app
          -- A returning queue loop always reaches process supervision. Retained
          -- failure health is available independently of live metric registration.
          --
          -- The metrics map is read for the log line, keyed by processor id and
          -- rendered by shibuya's own codecs so it cannot drift from the states
          -- the liveness probe reads. Expect it to be empty when the master shut
          -- down rather than an individual processor failing: shibuya clears the
          -- map on shutdown, so the states are already gone by the time this runs.
          -- It is logged anyway because the non-empty case — a failed processor
          -- under a master still standing — is the one an operator most needs, and
          -- an empty map is itself the signal that the whole supervisor went.
          metrics <- getAppMetrics app
          liftIO do
            Log.logError (envLogger env) "worker.queue.stopped" ["processors" .= metrics]
            throwIO (LoopExited QueueLoop)
    case appResult of
      Left err -> liftIO do
        Log.logError (envLogger env) "worker.loop.failed" ["error" .= Text.pack (show err)]
        ioError (userError ("run-job processor failed to start: " <> show err))
      Right () -> pure ()
  case result of
    Left perr -> do
      Log.logError (envLogger env) "worker.queue.failed" ["error" .= Text.pack (show perr)]
      ioError (userError ("run-job queue reconciliation failed: " <> show perr))
    Right () -> pure ()

-- | Serial processing with one inbox slot and one possible source-held row.
-- Cover two configured attempt windows plus a minute for admission/finalization.
-- The active handler renews to thirty seconds every ten seconds; queued work
-- retains this initial horizon. Crash redelivery of queued work may therefore
-- wait this long. Standard polling does not occupy a connection while idle.
queueTuningFor :: NominalDiffTime -> Either Text JobTuning
queueTuningFor timeout
  | timeout <= 0 = Left "run-job timeout must be positive"
  | visibility > toInteger (maxBound :: Int32) = Left "run-job timeout exceeds the supported visibility horizon"
  | otherwise = case mkJobTuning (fromInteger visibility) 1 (PollEvery 1) of
      Left failure -> Left (Text.pack (show failure))
      Right tuning -> Right (RunJobs.jobTuningFor tuning)
  where
    visibility = 2 * ceiling timeout + 60
