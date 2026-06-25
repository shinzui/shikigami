{-# LANGUAGE TypeApplications #-}

-- | The supervised worker (EP-5): a @shibuya@ @QueueProcessor@ over @pgmq@ that drains
-- the @shikigami_run_jobs@ queue and, for each job, runs the named agent end to end —
-- open a kioku session, run the behavior (EP-2), dispatch the agent's sinks (EP-3),
-- complete the session — and returns an @AckDecision@. Reuses
-- 'Shikigami.Agent.Run.runAgentWithMemory' (the EP-2 session/memory bracket) and
-- 'Shikigami.Sink.dispatch' (the EP-3 permission-gated sink dispatcher).
module Shikigami.Worker
  ( WorkerEnv (..),
    runWorker,
    handleRunJob,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.List (find)
import Data.Text qualified as Text
import Data.Time.Clock (secondsToNominalDiffTime)
import Effectful (IOE, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Pool (Pool)
import Kioku.App (AppEnv)
import Kioku.Id (idText)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError, runPgmq)
import Shibuya.Adapter.Pgmq (pgmqAdapter)
import Shibuya.Adapter.Pgmq.Config (defaultConfig)
import Shibuya.App (ProcessorId (..), SupervisionStrategy (IgnoreFailures), mkProcessor, runApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), RetryDelay (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Handler (Handler)
import Shibuya.Telemetry.Effect (runTracingNoop)
import Shikigami.Agent.Run (AgentRunResult (..), runAgentWithMemory)
import Shikigami.Api.Agent (AgentDecl (..))
import Shikigami.Api.RunJob (RunJob (..))
import Shikigami.Behavior.Run (BehaviorEnv)
import Shikigami.Prelude
import Shikigami.Sink (KawaConfig, KizashiConfig, SinkContext (..), SinkOutcome (..), SinkResult (..), dispatch)
import Shikigami.Sink.Permission (AgentIdentity (AgentIdentity))
import Shikigami.Trigger.Enqueue (runQueueName)
import System.IO (hPutStrLn, stderr)

-- | Everything the worker handler needs.
data WorkerEnv = WorkerEnv
  { workerPool :: !Pool,
    workerAppEnv :: !AppEnv,
    workerAgents :: ![AgentDecl],
    workerBehaviorEnv :: !BehaviorEnv,
    workerKizashi :: !KizashiConfig,
    workerKawa :: !KawaConfig
  }

-- | Boot the worker: build the pgmq adapter over @shikigami_run_jobs@, wrap the
-- orchestration handler, and run it under shibuya's supervisor (no-op tracing).
runWorker :: WorkerEnv -> IO ()
runWorker env = do
  hPutStrLn stderr "[shikigami.worker] starting; draining shikigami_run_jobs"
  result <-
    runEff . runErrorNoCallStack @PgmqRuntimeError . runPgmq (workerPool env) . runTracingNoop $ do
      adapter <- pgmqAdapter (defaultConfig runQueueName)
      let processor = mkProcessor adapter (runJobHandler env)
      appResult <- runApp IgnoreFailures 100 [(ProcessorId "shikigami_run_jobs", processor)]
      case appResult of
        Left err -> liftIO (hPutStrLn stderr ("[shikigami.worker] app error: " <> show err))
        Right h -> waitApp h
  case result of
    Left perr -> hPutStrLn stderr ("[shikigami.worker] pgmq error: " <> show perr)
    Right () -> pure ()

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
    Aeson.Success job ->
      case find ((== agentName job) . name) (workerAgents env) of
        Nothing -> do
          hPutStrLn stderr ("[shikigami.worker] unknown agent (dead-letter): " <> Text.unpack (agentName job))
          pure (AckDeadLetter (PoisonPill ("unknown agent " <> agentName job)))
        Just decl -> runOneAgent env job decl

-- | Run a resolved agent and dispatch its sinks.
runOneAgent :: WorkerEnv -> RunJob -> AgentDecl -> IO AckDecision
runOneAgent env job decl = do
  resE <- runAgentWithMemory (workerAppEnv env) (workerBehaviorEnv env) decl (triggerPayload job)
  case resE of
    Left err -> do
      hPutStrLn stderr ("[shikigami.worker] agent=" <> Text.unpack (agentName job) <> " behavior failed (retry): " <> Text.unpack err)
      pure (AckRetry (RetryDelay (secondsToNominalDiffTime 1)))
    Right result -> do
      let runId = idText (runSessionId result)
          identity = AgentIdentity (agentName job)
          dispatchOne (ordinal, sink) =
            dispatch
              SinkContext
                { sinkCtxIdentity = identity,
                  sinkCtxRunId = runId,
                  sinkCtxOrdinal = ordinal,
                  sinkCtxKizashi = workerKizashi env,
                  sinkCtxKawa = workerKawa env,
                  sinkCtxOccurredAt = Nothing
                }
              sink
              (behaviorOutput result)
      sinkResults <- mapM dispatchOne (zip [0 ..] (sinks decl))
      mapM_ (logSink (agentName job)) sinkResults
      let ack = classifyAck sinkResults
      hPutStrLn stderr ("[shikigami.worker] agent=" <> Text.unpack (agentName job) <> " session=" <> Text.unpack runId <> " -> " <> show ack)
      pure ack

-- | A transient sink failure ⇒ retry; everything else (delivered/stubbed/denied) ⇒ ok.
classifyAck :: [SinkResult] -> AckDecision
classifyAck results
  | any isFailed results = AckRetry (RetryDelay (secondsToNominalDiffTime 1))
  | otherwise = AckOk
  where
    isFailed r = case sinkResultOutcome r of
      Failed _ -> True
      _ -> False

logSink :: Text -> SinkResult -> IO ()
logSink agent r =
  hPutStrLn stderr ("[shikigami.sink] agent=" <> Text.unpack agent <> " sink=" <> show (sinkResultKind r) <> " -> " <> show (sinkResultOutcome r))
