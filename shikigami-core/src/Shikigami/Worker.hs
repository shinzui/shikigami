{-# LANGUAGE TypeApplications #-}

-- | The supervised worker (EP-5): a @shibuya@ @QueueProcessor@ over @pgmq@ that drains
-- the @shikigami_run_jobs@ queue and, for each job, drives the named agent through a
-- durable keiro workflow.
module Shikigami.Worker
  ( WorkerEnv (..),
    runWorker,
    handleRunJob,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently_)
import Control.Monad (forever)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Data.Time.Clock (secondsToNominalDiffTime)
import Effectful (IOE, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Pool (Pool)
import Keiro.Outbox (defaultPublishOptions, publishClaimedOutbox)
import Keiro.Workflow (WorkflowOutcome (..))
import Keiro.Workflow.Resume (runWorkflowResumeWorker)
import Keiro.Workflow.Sleep (runWorkflowTimerWorker)
import Kioku.App (AppEnv, runAppIO)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError, runPgmq)
import Shibuya.Adapter.Pgmq (pgmqAdapter)
import Shibuya.Adapter.Pgmq.Config (defaultConfig)
import Shibuya.App (ProcessorId (..), SupervisionStrategy (IgnoreFailures), mkProcessor, runApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), RetryDelay (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Handler (Handler)
import Shibuya.Telemetry.Effect (runTracingNoop)
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Api.Agent (AgentDecl (..))
import Shikigami.Api.RunJob (RunJob (..))
import Shikigami.Behavior.Run (BehaviorEnv)
import Shikigami.Prelude
import Shikigami.Sink (DanwaConfig, KawaConfig, KizashiConfig)
import Shikigami.Trigger.Enqueue (runQueueName)
import System.IO (hPutStrLn, stderr)

-- | Everything the worker handler needs.
data WorkerEnv = WorkerEnv
  { pool :: !Pool,
    appEnv :: !AppEnv,
    agents :: ![AgentDecl],
    behaviorEnv :: !BehaviorEnv,
    kizashi :: !KizashiConfig,
    kawa :: !KawaConfig,
    danwa :: !DanwaConfig
  }

-- | Boot the worker: build the pgmq adapter over @shikigami_run_jobs@, wrap the
-- orchestration handler, and run it under shibuya's supervisor (no-op tracing).
runWorker :: WorkerEnv -> IO ()
runWorker env = do
  hPutStrLn stderr "[shikigami.worker] starting; draining shikigami_run_jobs"
  concurrently_ (runQueueWorker env) (concurrently_ (runResumeWorker env) (concurrently_ (runOutboxPublisher env) (runApprovalTimerWorker env)))

runQueueWorker :: WorkerEnv -> IO ()
runQueueWorker env = do
  result <-
    runEff . runErrorNoCallStack @PgmqRuntimeError . runPgmq (pool env) . runTracingNoop $ do
      adapter <- pgmqAdapter (defaultConfig runQueueName)
      let processor = mkProcessor adapter (runJobHandler env)
      appResult <- runApp IgnoreFailures 100 [(ProcessorId "shikigami_run_jobs", processor)]
      case appResult of
        Left err -> liftIO (hPutStrLn stderr ("[shikigami.worker] app error: " <> show err))
        Right h -> waitApp h
  case result of
    Left perr -> hPutStrLn stderr ("[shikigami.worker] pgmq error: " <> show perr)
    Right () -> pure ()

runResumeWorker :: WorkerEnv -> IO ()
runResumeWorker env = do
  hPutStrLn stderr "[shikigami.worker] starting keiro workflow resume worker"
  let deps = agentRunDeps env
  result <- runAppIO (appEnv env) (runWorkflowResumeWorker (AgentWorkflow.agentRunRegistry deps))
  case result of
    Left err -> hPutStrLn stderr ("[shikigami.worker] resume worker store error: " <> show err)
    Right () -> pure ()

runOutboxPublisher :: WorkerEnv -> IO ()
runOutboxPublisher env = do
  hPutStrLn stderr "[shikigami.worker] starting sink outbox publisher"
  forever do
    let deps = agentRunDeps env
    result <- runAppIO (appEnv env) (publishClaimedOutbox (AgentWorkflow.publishSinkIntent deps) defaultPublishOptions Nothing)
    case result of
      Left err -> hPutStrLn stderr ("[shikigami.worker] outbox publisher store error: " <> show err)
      Right _summary -> pure ()
    threadDelay 1_000_000

runApprovalTimerWorker :: WorkerEnv -> IO ()
runApprovalTimerWorker env = do
  hPutStrLn stderr "[shikigami.worker] starting approval timeout timer worker"
  forever do
    now <- getCurrentTime
    result <- runAppIO (appEnv env) (runWorkflowTimerWorker Nothing now Approval.approvalTimeoutFireAction)
    case result of
      Left err -> hPutStrLn stderr ("[shikigami.worker] approval timer worker store error: " <> show err)
      Right _row -> pure ()
    threadDelay 1_000_000

-- | The shibuya handler: lift the (IO) orchestration into the worker's effect row.
runJobHandler :: (IOE :> es) => WorkerEnv -> Handler es Value
runJobHandler env (Ingested {envelope = Envelope {payload = p}}) =
  liftIO (handleRunJob env p)

-- | Orchestrate one drained job. Decodes the IP-7 'RunJob', resolves the agent, runs it
-- with memory, dispatches its sinks, and maps the outcome to an 'AckDecision'.
handleRunJob :: WorkerEnv -> Value -> IO AckDecision
handleRunJob env payloadV =
  case Aeson.fromJSON payloadV of
    Aeson.Error e -> do
      hPutStrLn stderr ("[shikigami.worker] invalid run job (dead-letter): " <> e)
      pure (AckDeadLetter (InvalidPayload (Text.pack e)))
    Aeson.Success job -> runOneAgent env job

-- | Run a resolved agent and dispatch its sinks.
runOneAgent :: WorkerEnv -> RunJob -> IO AckDecision
runOneAgent env job = do
  resE <- AgentWorkflow.runAgentRunWorkflow (agentRunDeps env) job
  case resE of
    Left err -> do
      hPutStrLn stderr ("[shikigami.worker] agent=" <> Text.unpack (agentName job) <> " workflow store error (retry): " <> show err)
      pure (AckRetry (RetryDelay (secondsToNominalDiffTime 1)))
    Right (Completed (Right _result)) -> do
      hPutStrLn stderr ("[shikigami.worker] agent=" <> Text.unpack (agentName job) <> " workflow completed")
      pure AckOk
    Right (Completed (Left err)) -> do
      hPutStrLn stderr ("[shikigami.worker] agent=" <> Text.unpack (agentName job) <> " workflow failed (retry): " <> Text.unpack err)
      if "unknown agent " `Text.isPrefixOf` err
        then pure (AckDeadLetter (PoisonPill err))
        else pure (AckRetry (RetryDelay (secondsToNominalDiffTime 1)))
    Right Suspended -> do
      hPutStrLn stderr ("[shikigami.worker] agent=" <> Text.unpack (agentName job) <> " workflow suspended")
      pure AckOk
    Right Cancelled -> pure (AckDeadLetter (PoisonPill ("workflow cancelled for " <> agentName job)))
    Right Failed -> pure (AckRetry (RetryDelay (secondsToNominalDiffTime 1)))
    Right ContinuedAsNew -> pure AckOk

agentRunDeps :: WorkerEnv -> AgentWorkflow.AgentRunDeps
agentRunDeps env =
  AgentWorkflow.AgentRunDeps
    { AgentWorkflow.appEnv = appEnv env,
      AgentWorkflow.behaviorEnv = behaviorEnv env,
      AgentWorkflow.agents = agents env,
      AgentWorkflow.kizashi = kizashi env,
      AgentWorkflow.kawa = kawa env,
      AgentWorkflow.danwa = danwa env,
      AgentWorkflow.hooks = AgentWorkflow.defaultAgentRunHooks,
      AgentWorkflow.approval = Approval.defaultApprovalEnv,
      AgentWorkflow.deadline = Nothing
    }
