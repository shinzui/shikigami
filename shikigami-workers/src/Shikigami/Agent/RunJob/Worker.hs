{-# LANGUAGE TypeApplications #-}

-- | Draining the @shikigami_run_jobs@ queue: one message becomes one agent run.
--
-- A \"run job\" is the message a fired trigger leaves on the queue, described by
-- 'Shikigami.Agent.RunJob.RunJob'. This module decodes one, decides which
-- durable workflow it belongs to, drives it, and maps the outcome onto the
-- acknowledgement the queue supervisor expects:
--
--   * @AckOk@ — the message is done and is removed.
--   * @AckRetry@ — the message becomes visible again after a delay.
--   * @AckDeadLetter@ — the message can never succeed and is set aside.
--
-- Getting that mapping wrong is how work is silently dropped or repeated
-- forever, so each case is decided explicitly below rather than by a catch-all.
-- The retry ceilings, lease durations, and failure taxonomy that should govern
-- those choices are owned by
-- @docs\/plans\/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md@;
-- this module preserves today's behavior unchanged.
module Shikigami.Agent.RunJob.Worker
  ( runJobHandler,
    handleRunJob,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.List (find)
import Data.Text qualified as Text
import Data.Time.Clock (secondsToNominalDiffTime)
import Effectful (IOE, runEff, (:>))
import Keiro.Workflow (WorkflowOutcome (..))
import Kioku.App (AppEnv (..))
import OpenTelemetry.Trace.Core qualified as Otel
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), RetryDelay (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Handler (Handler)
import Shibuya.Telemetry.Effect (SpanArguments, SpanKind (..), addAttribute, runTracing, withSpan')
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.RunJob (RunJob (..), TriggerKind (..))
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Integration.Danwa (AddressedMessage)
import Shikigami.Prelude
import Shikigami.Workers.Config (WorkerEnv (..), agentRunDeps, conversationEnv)
import System.IO (hPutStrLn, stderr)

-- | The shibuya handler: lift the orchestration into the worker's effect row.
runJobHandler :: (IOE :> es) => WorkerEnv -> Handler es Value
runJobHandler env (Message {envelope = Envelope {payload = p}}) =
  liftIO (handleRunJob env p)

-- | Orchestrate one drained job.
--
-- A payload that decodes as an addressed danwa message goes to the conversation
-- workflow; anything else goes to the agent-run workflow. A payload that is not
-- a 'RunJob' at all is dead-lettered immediately, because no amount of retrying
-- will make malformed JSON parse.
handleRunJob :: WorkerEnv -> Value -> IO AckDecision
handleRunJob env payloadV =
  case Aeson.fromJSON payloadV of
    Aeson.Error e -> do
      hPutStrLn stderr ("[shikigami.worker] invalid run job (dead-letter): " <> e)
      pure (AckDeadLetter (InvalidPayload (Text.pack e)))
    Aeson.Success job ->
      case Aeson.fromJSON (triggerPayload job) of
        Aeson.Success addressed -> runConversationAgent env job addressed
        Aeson.Error _ -> runOneAgent env job

-- | Drive one turn of a conversation agent.
runConversationAgent :: WorkerEnv -> RunJob -> AddressedMessage -> IO AckDecision
runConversationAgent env job addressed =
  case find ((== agentName job) . name) (agents env) of
    Nothing -> pure (AckDeadLetter (PoisonPill ("unknown agent " <> agentName job)))
    Just decl -> do
      result <- Conversation.runConversationTurn (conversationEnv env) decl addressed
      case result of
        Left err -> do
          hPutStrLn stderr ("[shikigami.worker] conversation turn failed (retry): " <> Text.unpack err)
          pure (AckRetry (RetryDelay (secondsToNominalDiffTime 1)))
        Right _ -> pure AckOk

-- | Run a resolved agent through the durable agent-run workflow and dispatch its sinks.
runOneAgent :: WorkerEnv -> RunJob -> IO AckDecision
runOneAgent env job =
  runEff . runTracing (tracer (appEnv env)) $
    withSpan' "agent.run" (spanArgs Consumer) \traceSpan -> do
      addAttribute traceSpan "agent.name" (agentName job)
      addAttribute traceSpan "trigger.kind" (triggerKindText (triggerKind job))
      addAttribute traceSpan "run.idempotency_key" (idempotencyKey job)
      addAttribute traceSpan "run.workflow_id" (idempotencyKey job)
      liftIO do
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

triggerKindText :: TriggerKind -> Text
triggerKindText = \case
  TriggeredBySchedule -> "schedule"
  TriggeredByStream -> "stream"
  TriggeredByEvent -> "event"
  TriggeredByDelegation -> "delegation"

spanArgs :: SpanKind -> SpanArguments
spanArgs spanKind =
  Otel.defaultSpanArguments {Otel.kind = spanKind}
