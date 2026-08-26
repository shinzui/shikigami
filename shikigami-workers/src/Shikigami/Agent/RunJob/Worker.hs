{-# LANGUAGE TypeApplications #-}

-- | The typed @shikigami_run_jobs@ consumer.
--
-- The producer deliberately still writes the historical bare 'RunJob' JSON.
-- 'aesonJobCodec' keeps that wire stable while moving decode failures, retry
-- ceilings, and DLQ routing behind the fleet-standard 'Job' abstraction.
module Shikigami.Agent.RunJob.Worker
  ( runJob,
    handleRunJob,
    DrainAdmission (..),
    admitRunJob,
    admitRunJobWith,
    drainAdmissionOutcome,
    RunRoute (..),
    routeRunJob,
    routeErrorJobOutcome,
    agentJobOutcome,
    conversationJobOutcome,
    transientBehaviorJobOutcome,
    withVisibilityHeartbeat,
    withVisibilityHeartbeatEvery,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception qualified as Exception
import Control.Monad (forever)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Data.List (find)
import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime)
import Data.Void (absurd)
import Effectful (Eff, IOE, Limit (Limited), Persistence (Persistent), UnliftStrategy (ConcUnlift), runEff, withEffToIO, (:>))
import Hasql.Pool qualified
import Keiro.PGMQ (Job (..), JobContext (..), JobOutcome (..), aesonJobCodec, defaultRetryPolicy, queueRef)
import Keiro.Workflow (WorkflowOutcome (..))
import Kioku.App (AppEnv (..))
import OpenTelemetry.Trace.Core qualified as Otel
import Shibuya.Telemetry.Effect (SpanArguments, SpanKind (..), addAttribute, runTracing, withSpan')
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Principal (AgentIdentity (..), meiboPrincipal, principalText)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (..))
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Behavior.Error (TransientBehaviorFailure (..), boundedBehaviorDetail)
import Shikigami.Directory qualified as Directory
import Shikigami.Directory.Store qualified as DirectoryStore
import Shikigami.Integration.Danwa (AddressedMessage)
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Telemetry.Metrics qualified as Metrics
import Shikigami.Workers.Config (WorkerEnv (..), agentRunDeps, conversationEnv, envDirectory, envLogger, envMetrics)

-- | The queue contract for run jobs. Its codec intentionally preserves the
-- existing unwrapped Aeson payload until a dual-read migration can introduce a
-- versioned envelope.
runJob :: Job RunJob
runJob =
  Job
    { jobName = "shikigami_run_jobs",
      jobQueue = queueRef "shikigami_run_jobs",
      jobCodec = aesonJobCodec,
      jobPolicy = defaultRetryPolicy
    }

-- | Process one decoded delivery while renewing its PGMQ visibility lease.
-- Codec failures never reach this function: @keiro-pgmq@ dead-letters them at
-- the typed boundary.
handleRunJob :: (IOE :> es) => WorkerEnv -> JobContext es -> RunJob -> Eff es JobOutcome
handleRunJob env context job =
  withVisibilityHeartbeat context do
    liftIO (admitRunJob env job) >>= \case
      DrainSkipped runSkip -> do
        liftIO $
          jobLog
            env
            job
            Log.Info
            "worker.job.lifecycle_skipped"
            [ "principal_id" Aeson..= DirectoryStore.principalId runSkip,
              "route" Aeson..= DirectoryStore.detail runSkip,
              "reason" Aeson..= DirectoryStore.reason runSkip
            ]
        pure Done
      DrainAuditFailed problem -> do
        liftIO $
          jobLog
            env
            job
            Log.Error
            "worker.job.lifecycle_skip_failed"
            [ "error" Aeson..= problem,
              "reason" Aeson..= ("skip_audit_failed" :: Text)
            ]
        pure (fromMaybe RetryDefault (drainAdmissionOutcome (DrainAuditFailed problem)))
      DrainAllowed admittedJob -> do
        liftIO (runMetric Metrics.recordRunStarted env admittedJob)
        attemptResult <- liftIO (Exception.try @TransientBehaviorFailure (dispatchRunJob env admittedJob))
        case attemptResult of
          Left failure@(TransientBehaviorFailure {detail}) -> do
            liftIO do
              runMetric Metrics.recordRunFailed env admittedJob
              runMetric Metrics.recordRunRetried env admittedJob
            liftIO $
              jobLog
                env
                admittedJob
                Log.Error
                "worker.job.retried"
                [ "error" Aeson..= detail,
                  "reason" Aeson..= ("transient_behavior_failure" :: Text)
                ]
            pure (transientBehaviorJobOutcome failure)
          Right outcome -> pure outcome

data DrainAdmission
  = DrainAllowed !RunJob
  | DrainSkipped !DirectoryStore.RunSkip
  | DrainAuditFailed !Text
  deriving stock (Eq, Show)

-- | Queue disposition for a completed drain gate. Allowed jobs continue to
-- routing, durable refusals acknowledge, and audit failures retry.
drainAdmissionOutcome :: DrainAdmission -> Maybe JobOutcome
drainAdmissionOutcome = \case
  DrainAllowed _ -> Nothing
  DrainSkipped _ -> Just Done
  DrainAuditFailed _ -> Just RetryDefault

-- | Consult lifecycle immediately before route selection or workflow work.
-- A durable refusal is acknowledged; a refusal whose audit row cannot be
-- committed is retried so the queue remains the source of truth.
admitRunJob :: WorkerEnv -> RunJob -> IO DrainAdmission
admitRunJob env = admitRunJobWith (pool env) (envDirectory env) (agents env)

-- | The drain gate with its concrete dependencies exposed for focused tests.
admitRunJobWith :: Hasql.Pool.Pool -> Directory.DirectoryHandle -> [AgentDecl] -> RunJob -> IO DrainAdmission
admitRunJobWith storePool directory declarations job =
  case find ((== agentName job) . name) declarations of
    Nothing -> recordRefusal Nothing "unknown agent declaration"
    Just AgentDecl {name, identity} -> do
      let declaredPrincipalId = principalOf <$> identity
      admitted <- case Shikigami.Agent.RunJob.identity job of
        UnresolvedLegacyIdentity -> Directory.identityAdmission directory declaredPrincipalId name
        recorded -> pure (Right recorded)
      case admitted of
        Left reason -> recordRefusal declaredPrincipalId reason
        Right recorded -> do
          decision <- Directory.consultIdentityLifecycle directory recorded
          case lifecycleRefusal (principalText <$> meiboPrincipal recorded) decision of
            Nothing -> pure (DrainAllowed (job {Shikigami.Agent.RunJob.identity = recorded}))
            Just (resolvedPrincipalId, skipReason) -> recordRefusal resolvedPrincipalId skipReason
  where
    principalOf identityDecl = identityDecl ^. #principal

    recordRefusal resolvedPrincipalId skipReason = do
      let runSkip =
            DirectoryStore.RunSkip
              { DirectoryStore.agentName = agentName job,
                DirectoryStore.principalId = resolvedPrincipalId,
                DirectoryStore.stage = DirectoryStore.DrainStage,
                DirectoryStore.detail = routeKindText (routeKind job),
                DirectoryStore.reason = skipReason,
                DirectoryStore.idempotencyKey = idempotencyKey job
              }
      DirectoryStore.recordRunSkip storePool runSkip >>= \case
        Left problem -> pure (DrainAuditFailed problem)
        Right () -> pure (DrainSkipped runSkip)

lifecycleRefusal :: Maybe Text -> Directory.LifecycleDecision -> Maybe (Maybe Text, Text)
lifecycleRefusal declaredPrincipalId = \case
  Directory.AllowRun _ -> Nothing
  Directory.SkipRun principal skipReason -> Just (Just (Directory.principalId principal), skipReason)
  Directory.UnknownPrincipal identifier -> Just (declaredPrincipalId, "unknown principal: " <> identifier)
  Directory.DirectoryUnavailable problem -> Just (declaredPrincipalId, "directory unavailable: " <> problem)

routeKindText :: RunRouteKind -> Text
routeKindText = \case
  AgentWorkflowRoute -> "agent_run"
  ConversationWorkflowRoute -> "conversation"
  InferredLegacyRoute -> "inferred_legacy"

-- | Production heartbeat policy: after ten seconds, extend visibility to thirty
-- seconds from now, and repeat until work completes.
withVisibilityHeartbeat :: (IOE :> es) => JobContext es -> Eff es a -> Eff es a
withVisibilityHeartbeat = withVisibilityHeartbeatEvery 10 30

-- | Run work and its lease-renewal loop as linked peers. Work completion
-- cancels the heartbeat. A lease-extension failure cancels the work and escapes,
-- preventing acknowledgement. The explicit concurrent unlift is required
-- because both branches use the job processor's effect environment.
--
-- Exported so the worker-path integration test can use sub-second timings while
-- production keeps the fixed 10/30-second policy above.
withVisibilityHeartbeatEvery :: (IOE :> es) => NominalDiffTime -> NominalDiffTime -> JobContext es -> Eff es a -> Eff es a
withVisibilityHeartbeatEvery interval extension context work =
  withEffToIO (ConcUnlift Persistent (Limited 2)) $ \runInIO -> do
    let heartbeat = forever do
          threadDelay (nominalMicroseconds interval)
          runInIO (extendLease context extension)
    raced <- Async.race (runInIO work) heartbeat
    pure (either id absurd raced)

nominalMicroseconds :: NominalDiffTime -> Int
nominalMicroseconds duration =
  max 1 (ceiling (realToFrac duration * (1_000_000 :: Double)))

-- | Which workflow one delivery is for, decided from the producer's declared
-- route and never from the payload's shape.
data RunRoute
  = ConversationRoute !AddressedMessage
  | AgentRunRoute
  | -- | The producer declared a conversation but its payload is not an
    -- addressed message. That is a producer bug, and running the other workflow
    -- instead would hide it.
    RouteError !Text

-- | The pure routing decision. Payload decoding validates the declared route; it
-- never chooses one. 'InferredLegacyRoute' is the single exception, and only
-- because it means "enqueued before the discriminator existed".
routeRunJob :: RunJob -> RunRoute
routeRunJob job = case routeKind job of
  AgentWorkflowRoute -> AgentRunRoute
  ConversationWorkflowRoute ->
    case Aeson.fromJSON (triggerPayload job) of
      Aeson.Success addressed -> ConversationRoute addressed
      Aeson.Error err -> RouteError (Text.pack err)
  InferredLegacyRoute ->
    case Aeson.fromJSON (triggerPayload job) of
      Aeson.Success addressed -> ConversationRoute addressed
      Aeson.Error _ -> AgentRunRoute

dispatchRunJob :: WorkerEnv -> RunJob -> IO JobOutcome
dispatchRunJob env job = do
  let route = routeRunJob job
  when (routeKind job == InferredLegacyRoute) $
    jobLog
      env
      job
      Log.Warn
      "worker.job.route_inferred"
      ["resolved_route" Aeson..= routeText route]
  case route of
    ConversationRoute addressed -> runConversationAgent env job addressed
    AgentRunRoute -> runOneAgent env job
    RouteError detail -> do
      runMetric Metrics.recordRunFailed env job
      runMetric Metrics.recordRunDeadLettered env job
      jobLog
        env
        job
        Log.Error
        "worker.job.dead_lettered"
        [ "error" Aeson..= detail,
          "reason" Aeson..= ("invalid_route_payload" :: Text)
        ]
      pure (routeErrorJobOutcome detail)

-- | A declared route whose payload does not match it is a permanent producer
-- bug, so the delivery dead-letters rather than running the other workflow.
-- Kept as a named mapping, like 'transientBehaviorJobOutcome', so the outcome
-- table can pin it without manufacturing a full worker environment.
routeErrorJobOutcome :: Text -> JobOutcome
routeErrorJobOutcome = deadOutcome "invalid_route_payload"

routeText :: RunRoute -> Text
routeText = \case
  ConversationRoute _ -> "conversation"
  AgentRunRoute -> "agent_run"
  RouteError _ -> "route_error"

-- | Drive one turn of a conversation agent.
runConversationAgent :: WorkerEnv -> RunJob -> AddressedMessage -> IO JobOutcome
runConversationAgent env job addressed =
  case find ((== agentName job) . name) (agents env) of
    Nothing -> do
      let detail = "unknown agent " <> agentName job
      runMetric Metrics.recordRunFailed env job
      runMetric Metrics.recordRunDeadLettered env job
      jobLog
        env
        job
        Log.Error
        "worker.conversation.dead_lettered"
        [ "error" Aeson..= detail,
          "reason" Aeson..= ("unknown_agent" :: Text)
        ]
      pure (deadOutcome "unknown_agent" detail)
    Just decl -> do
      result <- Conversation.runConversationTurnWithIdentity (conversationEnv env) decl (job ^. #identity) addressed
      case result of
        Left (Conversation.ConversationTransientFailure err) -> do
          runMetric Metrics.recordRunFailed env job
          runMetric Metrics.recordRunRetried env job
          jobLog
            env
            job
            Log.Error
            "worker.conversation.retried"
            [ "error" Aeson..= err,
              "reason" Aeson..= ("transient_conversation_failure" :: Text)
            ]
          pure ()
        Left (Conversation.ConversationPermanentFailure err) -> do
          runMetric Metrics.recordRunFailed env job
          runMetric Metrics.recordRunDeadLettered env job
          jobLog
            env
            job
            Log.Error
            "worker.conversation.dead_lettered"
            [ "error" Aeson..= err,
              "reason" Aeson..= ("permanent_conversation_failure" :: Text)
            ]
          pure ()
        Left (Conversation.ConversationTerminalFailure err) -> do
          runMetric Metrics.recordRunFailed env job
          runMetric Metrics.recordRunDeadLettered env job
          jobLog
            env
            job
            Log.Error
            "worker.conversation.dead_lettered"
            [ "error" Aeson..= err,
              "reason" Aeson..= ("terminal_conversation_failure" :: Text)
            ]
          pure ()
        -- Info, not error. A message arriving while the agent is still answering
        -- the previous one is the routine shape of a busy conversation, not a
        -- fault; it is redelivered by the queue's retry policy as backpressure.
        -- Logging it at error level -- which is what happened before this arm
        -- existed, because a busy conversation was indistinguishable from a
        -- transient failure -- makes the ordinary case look like an incident.
        Left (Conversation.ConversationBusy detail) ->
          do
            runMetric Metrics.recordRunFailed env job
            runMetric Metrics.recordRunRetried env job
            jobLog
              env
              job
              Log.Info
              "worker.conversation.redelivered"
              [ "detail" Aeson..= detail,
                "reason" Aeson..= ("conversation_busy" :: Text)
              ]
        Right _ -> do
          runMetric Metrics.recordRunCompleted env job
          jobLog env job Log.Info "worker.conversation.completed" []
      pure (conversationJobOutcome result)

-- | Run a resolved agent through the durable agent-run workflow and dispatch
-- its sinks.
runOneAgent :: WorkerEnv -> RunJob -> IO JobOutcome
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
            runMetric Metrics.recordRunFailed env job
            runMetric Metrics.recordRunRetried env job
            jobLog
              env
              job
              Log.Error
              "worker.job.retried"
              [ "error" Aeson..= Text.pack (show err),
                "reason" Aeson..= ("store_error" :: Text)
              ]
            pure ()
          Right (Completed (Right _result)) -> do
            runMetric Metrics.recordRunCompleted env job
            jobLog env job Log.Info "worker.job.completed" []
            pure ()
          Right (Completed (Left (AgentWorkflow.LegacyBehaviorFailure err))) -> do
            runMetric Metrics.recordRunFailed env job
            runMetric Metrics.recordRunRetried env job
            jobLog
              env
              job
              Log.Error
              "worker.job.retried"
              [ "error" Aeson..= err,
                "reason" Aeson..= ("legacy_behavior_failure" :: Text)
              ]
            pure ()
          Right (Completed (Left failure@(AgentWorkflow.PermanentAgentRunFailure _))) -> do
            let err = AgentWorkflow.agentRunFailureDetail failure
            runMetric Metrics.recordRunFailed env job
            runMetric Metrics.recordRunDeadLettered env job
            jobLog
              env
              job
              Log.Error
              "worker.job.dead_lettered"
              [ "error" Aeson..= err,
                "reason" Aeson..= ("permanent_workflow_failure" :: Text)
              ]
            pure ()
          Right Suspended -> do
            jobLog env job Log.Info "worker.job.suspended" []
            pure ()
          Right Cancelled -> do
            runMetric Metrics.recordRunFailed env job
            runMetric Metrics.recordRunDeadLettered env job
            jobLog
              env
              job
              Log.Warn
              "worker.job.dead_lettered"
              ["reason" Aeson..= ("workflow_cancelled" :: Text)]
            pure ()
          Right Failed -> do
            runMetric Metrics.recordRunFailed env job
            runMetric Metrics.recordRunDeadLettered env job
            jobLog
              env
              job
              Log.Error
              "worker.job.dead_lettered"
              ["reason" Aeson..= ("workflow_failed" :: Text)]
            pure ()
          Right ContinuedAsNew -> do
            jobLog env job Log.Info "worker.job.continued_as_new" []
            pure ()
        pure (agentJobOutcome (agentName job) resE)

-- | The complete agent-workflow outcome table. The store error is deliberately
-- polymorphic: its value is diagnostic only, while every store failure is a
-- transport retry.
agentJobOutcome :: Text -> Either e (WorkflowOutcome (Either AgentWorkflow.AgentRunFailure a)) -> JobOutcome
agentJobOutcome agent = \case
  Left _storeError -> RetryDefault
  Right (Completed (Right _result)) -> Done
  Right (Completed (Left (AgentWorkflow.LegacyBehaviorFailure _))) -> RetryDefault
  Right (Completed (Left (AgentWorkflow.PermanentAgentRunFailure detail))) ->
    deadOutcome "permanent_workflow_failure" detail
  Right Suspended -> Done
  Right Cancelled -> deadOutcome "workflow_cancelled" ("workflow cancelled for " <> agent)
  Right Failed -> deadOutcome "workflow_failed" ("workflow failed for " <> agent)
  Right ContinuedAsNew -> Done

-- | Conversation completion uses the same retry/permanent split as agent runs.
conversationJobOutcome :: Either Conversation.ConversationTurnFailure a -> JobOutcome
conversationJobOutcome = \case
  Left (Conversation.ConversationTransientFailure _) -> RetryDefault
  -- Same disposition as a transient failure, different meaning: the queue's
  -- retry is the backpressure that hands this message to the conversation once
  -- it is free.
  Left (Conversation.ConversationBusy _) -> RetryDefault
  Left (Conversation.ConversationPermanentFailure detail) ->
    deadOutcome "permanent_conversation_failure" detail
  Left (Conversation.ConversationTerminalFailure detail) ->
    deadOutcome "terminal_conversation_failure" detail
  Right _result -> Done

-- | A transient attempt exception is the initial-drive retry case. Kept as a
-- named mapping so the outcome table can pin it without manufacturing a full
-- worker environment.
transientBehaviorJobOutcome :: TransientBehaviorFailure -> JobOutcome
transientBehaviorJobOutcome _ = RetryDefault

deadOutcome :: Text -> Text -> JobOutcome
deadOutcome reason detail =
  Dead (boundedBehaviorDetail ("shikigami." <> reason <> ": " <> detail))

-- | Every outcome line for one job carries the same identifying fields.
jobLog :: WorkerEnv -> RunJob -> Log.Level -> Text -> [Pair] -> IO ()
jobLog env job level event fields =
  Log.logEvent
    (envLogger env)
    level
    event
    ( [ "agent" Aeson..= agentName job,
        Log.runIdKey Aeson..= idempotencyKey job,
        "trigger_kind" Aeson..= triggerKindText (triggerKind job)
      ]
        <> fields
    )

triggerKindText :: TriggerKind -> Text
triggerKindText = \case
  TriggeredBySchedule -> "schedule"
  TriggeredByStream -> "stream"
  TriggeredByEvent -> "event"
  TriggeredByDelegation -> "delegation"

runMetric :: (Metrics.ShikigamiMetrics -> Text -> Text -> IO ()) -> WorkerEnv -> RunJob -> IO ()
runMetric record env job =
  record (envMetrics env) (agentName job) (triggerKindText (triggerKind job))

spanArgs :: SpanKind -> SpanArguments
spanArgs spanKind =
  Otel.defaultSpanArguments {Otel.kind = spanKind}
