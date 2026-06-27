module Shikigami.Agent.Workflow
  ( AgentRunDeps (..),
    AgentRunHooks (..),
    defaultAgentRunHooks,
    agentRunWorkflowName,
    agentRunWorkflow,
    runAgentRunWorkflow,
    agentRunRegistry,
    publishSinkIntent,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Bifunctor (first)
import Data.Foldable (traverse_)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Keiro.Integration.Event (IntegrationContentType (ApplicationJson), IntegrationEvent (..), decodeJsonIntegrationEvent, encodeJsonIntegrationEvent)
import Keiro.Outbox (OutboxId (..), OutboxMessage (..), OutboxRow (..), PublishOutcome (..), enqueueOutboxTx)
import Keiro.Workflow
  ( JournalAppendOutcome (..),
    StepName (..),
    Workflow,
    WorkflowId (..),
    WorkflowJournalEvent (StepRecorded),
    WorkflowName (..),
    WorkflowOutcome,
    currentRunGeneration,
    currentWorkflow,
    prepareJournalAppend,
    runWorkflow,
    step,
  )
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Kioku.Api.Types (Confidence (MediumConfidence), MemoryType (MemoryPattern))
import Kioku.App (AppEffects, AppEnv (..))
import Kioku.Id (MemoryId, SessionId, genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Session qualified as Session
import Kioku.Session.Domain (CompleteSessionData (..), FailSessionData (..), StartSessionData (..))
import Kiroku.Store.Effect (Store, runStorePool)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Shibuya.Telemetry.Effect (runTracing)
import Shikigami.Agent.Approval (ApprovalDecision (..), ApprovalEnv (..), ApprovalRequirement (..), awaitApproval)
import Shikigami.Agent.Run (AgentRunResult (..), behaviorKindText, recallPriorLearnings, recallQuery, renderLearning)
import Shikigami.Api.Agent (AgentDecl (..), Sink)
import Shikigami.Api.RunJob (RunJob (..))
import Shikigami.Behavior.Run (BehaviorEnv, runBehavior)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Prelude
import Shikigami.Sink (KawaConfig, KizashiConfig, SinkContext (..), SinkOutcome (..), SinkResult (..), checkGrant, dispatch, sinkKindOf)
import Shikigami.Sink.Permission (AgentIdentity (AgentIdentity), Denied (..), sinkKindText)

data AgentRunDeps = AgentRunDeps
  { appEnv :: !AppEnv,
    behaviorEnv :: !BehaviorEnv,
    agents :: ![AgentDecl],
    kizashi :: !KizashiConfig,
    kawa :: !KawaConfig,
    hooks :: !AgentRunHooks,
    approval :: !(SessionId -> ApprovalEnv),
    deadline :: !(Maybe NominalDiffTime)
  }

data AgentRunHooks = AgentRunHooks
  { beforeStepBody :: !(StepName -> IO ()),
    afterStepBody :: !(StepName -> IO ())
  }

data SinkIntent = SinkIntent
  { agent :: !Text,
    runId :: !Text,
    ordinal :: !Int,
    occurredAt :: !(Maybe UTCTime),
    sink :: !Sink,
    output :: !Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

defaultAgentRunHooks :: AgentRunHooks
defaultAgentRunHooks =
  AgentRunHooks
    { beforeStepBody = \_ -> pure (),
      afterStepBody = \_ -> pure ()
    }

agentRunWorkflowName :: WorkflowName
agentRunWorkflowName = WorkflowName "shikigami.agent-run"

agentRunWorkflow ::
  AgentRunDeps ->
  Maybe RunJob ->
  Eff (Workflow : AppEffects) (Either Text AgentRunResult)
agentRunWorkflow deps mJob = do
  job <- runStep deps (StepName "ingest-job") (ingestJob mJob)
  mDecl <- runStep deps (StepName "lookup-agent") (pure (find ((== agentName job) . name) (agents deps)))
  case mDecl of
    Nothing -> pure (Left ("unknown agent " <> agentName job))
    Just decl -> runResolvedAgent deps job decl

runAgentRunWorkflow ::
  AgentRunDeps ->
  RunJob ->
  IO (Either StoreError (WorkflowOutcome (Either Text AgentRunResult)))
runAgentRunWorkflow deps job =
  let env = appEnv deps
   in runEff
        . runTracing (tracer env)
        . runErrorNoCallStack
        . runStorePool (store env)
        $ runWorkflow
          agentRunWorkflowName
          (WorkflowId (idempotencyKey job))
          (agentRunWorkflow deps (Just job))

agentRunRegistry :: AgentRunDeps -> WorkflowRegistry AppEffects
agentRunRegistry deps =
  Map.singleton agentRunWorkflowName (WorkflowDef \_wid -> agentRunWorkflow deps Nothing)

ingestJob :: (IOE :> es) => Maybe RunJob -> Eff es RunJob
ingestJob = \case
  Just job -> pure job
  Nothing -> liftIO (ioError (userError "agent run workflow resumed before ingest-job was journaled"))

runResolvedAgent ::
  AgentRunDeps ->
  RunJob ->
  AgentDecl ->
  Eff (Workflow : AppEffects) (Either Text AgentRunResult)
runResolvedAgent deps job decl = do
  sid <- runStep deps (StepName "open-session") (openSession deps decl)
  prior <- runStep deps (StepName "recall") (liftIO (recallPriorLearnings (appEnv deps) (agentScope (name decl)) (recallQuery decl (behaviorKindText (behavior decl)))))
  behaviorE <- runStep deps (StepName "run-behavior") (runBehaviorStep deps decl job)
  case behaviorE of
    Left err -> do
      _ <- runStep deps (StepName "fail-session") (failSession deps sid err)
      pure (Left err)
    Right output -> do
      approvedSinks <- approveSinks deps sid job decl output
      sinkResults <- enqueueSinkIntents job (decl {sinks = approvedSinks}) sid output
      liftIO (traverse_ (logSinkResult job) sinkResults)
      mem <- runStep deps (StepName "record") (recordLearning deps decl sid output)
      _ <- runStep deps (StepName "complete") (completeSession deps sid)
      pure
        ( Right
            AgentRunResult
              { runSessionId = sid,
                recalledPrior = prior,
                behaviorOutput = output,
                recordedMemId = mem
              }
        )

runStep ::
  (Workflow :> es, IOE :> es, ToJSON a, FromJSON a) =>
  AgentRunDeps ->
  StepName ->
  Eff es a ->
  Eff es a
runStep deps stepName action =
  step stepName do
    liftIO (beforeStepBody (hooks deps) stepName)
    result <- action
    liftIO (afterStepBody (hooks deps) stepName)
    pure result

approveSinks ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  AgentRunDeps ->
  SessionId ->
  RunJob ->
  AgentDecl ->
  Value ->
  Eff es [Sink]
approveSinks deps sid job decl output =
  catMaybes <$> traverse approve (zip [0 :: Int ..] (sinks decl))
  where
    env = approval deps sid

    approve (ordinal, sink) = do
      let kind = sinkKindOf sink
      requirement <- liftIO (requiresApproval env (AgentIdentity (agentName job)) kind output)
      case requirement of
        ApprovalNotRequired -> pure (Just sink)
        ApprovalRequired request -> do
          decision <- awaitApproval env (approvalStepName ordinal kind) request (deadline deps)
          pure case decision of
            Approved _ -> Just sink
            Rejected _ -> Nothing
            TimedOut -> Nothing

    approvalStepName ordinal kind =
      StepName ("approval:" <> sinkKindText kind <> ":" <> Text.pack (show ordinal))

openSession :: (IOE :> es) => AgentRunDeps -> AgentDecl -> Eff es SessionId
openSession deps decl = liftIO do
  startedAt' <- getCurrentTime
  sid <- genSessionId
  let focusTxt = behaviorKindText (behavior decl)
  _ <-
    Session.start
      StartSessionData
        { sessionId = sid,
          agentId = name decl,
          focus = focusTxt,
          scope = agentScope (name decl),
          subjectRef = Just (idText sid),
          previousSessionId = Nothing,
          startedAt = startedAt'
        }
      & runKioku deps
  pure sid

runBehaviorStep :: (IOE :> es) => AgentRunDeps -> AgentDecl -> RunJob -> Eff es (Either Text Value)
runBehaviorStep deps decl job =
  liftIO (first (Text.pack . show) <$> runBehavior (behaviorEnv deps) decl (triggerPayload job))

failSession :: (IOE :> es) => AgentRunDeps -> SessionId -> Text -> Eff es ()
failSession deps sid err = liftIO do
  failedAt' <- getCurrentTime
  void $
    Session.failSession
      FailSessionData
        { sessionId = sid,
          failedAt = failedAt',
          errorMessage = err
        }
      & runKioku deps

enqueueSinkIntents ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  RunJob ->
  AgentDecl ->
  SessionId ->
  Value ->
  Eff es [SinkResult]
enqueueSinkIntents job decl sid output = do
  (workflowName, workflowId) <- currentWorkflow
  generation <- currentRunGeneration
  now <- liftIO getCurrentTime
  prepared <- liftIO (traverse (buildSinkIntent workflowId) (zip [0 ..] (sinks decl)))
  let results = fst <$> prepared
      messages = mapMaybe snd prepared
      encoded = Aeson.toJSON results
  appendTx <- prepareJournalAppend workflowName workflowId generation (StepRecorded (unStepName dispatchSinksStep) encoded now)
  txResult <- runTransaction do
    appendTx >>= \case
      JournalAppended {} -> do
        traverse_ enqueueOutboxTx messages
        pure (Right results)
      JournalAlreadyPresent stored ->
        case parseEither Aeson.parseJSON stored of
          Right replayed -> pure (Right replayed)
          Left err -> pure (Left ("dispatch-sinks replay decode failed: " <> Text.pack err))
      JournalAppendConflict err ->
        pure (Left ("dispatch-sinks journal append conflict: " <> Text.pack (show err)))
  case txResult of
    Right results' -> pure results'
    Left err -> liftIO (ioError (userError (Text.unpack err)))
  where
    dispatchSinksStep = StepName "dispatch-sinks"
    runIdText = idText sid

    buildSinkIntent workflowId (ordinal, sink) = do
      let RunJob {occurredAt = jobOccurredAt} = job
      let kind = sinkKindOf sink
      checkGrant (AgentIdentity (agentName job)) kind <&> \case
        Left (Denied reason) ->
          (SinkResult kind (DeniedOutcome reason), Nothing)
        Right () ->
          let intent =
                SinkIntent
                  { agent = agentName job,
                    runId = runIdText,
                    ordinal,
                    occurredAt = Just jobOccurredAt,
                    sink,
                    output
                  }
              messageId = sinkMessageId workflowId ordinal
              event = sinkIntentEvent messageId runIdText jobOccurredAt intent
              outboxId = deterministicOutboxId workflowId ordinal
           in (SinkResult kind (Delivered ("outbox:" <> messageId)), Just (OutboxMessage outboxId event))

sinkIntentEvent :: Text -> Text -> UTCTime -> SinkIntent -> IntegrationEvent
sinkIntentEvent messageId runId occurredAt intent =
  encodeJsonIntegrationEvent
    IntegrationEvent
      { messageId,
        source = "shinzui/shikigami",
        destination = "shikigami.sink.v1",
        key = Just runId,
        eventType = "shikigami.sink.dispatch-requested",
        schemaVersion = 1,
        contentType = ApplicationJson,
        schemaReference = Nothing,
        sourceEventId = Nothing,
        sourceGlobalPosition = Nothing,
        payloadBytes = mempty,
        occurredAt,
        causationId = Nothing,
        correlationId = Nothing,
        traceContext = Nothing,
        attributes = Nothing
      }
    intent

sinkMessageId :: WorkflowId -> Int -> Text
sinkMessageId workflowId ordinal =
  unWorkflowId workflowId <> ":sink:" <> Text.pack (show ordinal)

deterministicOutboxId :: WorkflowId -> Int -> OutboxId
deterministicOutboxId workflowId ordinal =
  OutboxId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      fmap (fromIntegral . fromEnum) $
        Text.unpack ("shikigami:sink:" <> sinkMessageId workflowId ordinal)

publishSinkIntent :: (IOE :> es) => AgentRunDeps -> OutboxRow -> Eff es PublishOutcome
publishSinkIntent deps row =
  let OutboxRow {event = integrationEvent} = row
   in case decodeJsonIntegrationEvent integrationEvent of
        Left err -> pure (PublishFailed (Text.pack (show err)))
        Right SinkIntent {agent, runId, ordinal, occurredAt, sink, output} -> liftIO do
          result <-
            dispatch
              SinkContext
                { sinkCtxIdentity = AgentIdentity agent,
                  sinkCtxRunId = runId,
                  sinkCtxOrdinal = ordinal,
                  sinkCtxKizashi = kizashi deps,
                  sinkCtxKawa = kawa deps,
                  sinkCtxOccurredAt = occurredAt
                }
              sink
              output
          pure $ case sinkResultOutcome result of
            Failed err -> PublishFailed err
            _ -> PublishSucceeded

recordLearning :: (IOE :> es) => AgentRunDeps -> AgentDecl -> SessionId -> Value -> Eff es (Maybe MemoryId)
recordLearning deps decl sid output = liftIO do
  mid <- genMemoryId
  recordedAt' <- getCurrentTime
  _ <-
    Memory.record
      RecordMemoryData
        { memoryId = mid,
          agentId = name decl,
          sessionId = Just sid,
          scope = agentScope (name decl),
          memoryType = MemoryPattern,
          content = renderLearning output,
          priority = 100,
          confidence = MediumConfidence,
          tags = Set.fromList ["agent-run", behaviorKindText (behavior decl)],
          supersedes = Nothing,
          recordedAt = recordedAt'
        }
      & runKioku deps
  pure (Just mid)

completeSession :: (IOE :> es) => AgentRunDeps -> SessionId -> Eff es ()
completeSession deps sid = liftIO do
  completedAt' <- getCurrentTime
  void $
    Session.complete
      CompleteSessionData
        { sessionId = sid,
          completedAt = completedAt',
          modelUsed = Nothing,
          summary = Just "agent-run completed"
        }
      & runKioku deps

runKioku :: AgentRunDeps -> Eff AppEffects a -> IO (Either StoreError a)
runKioku deps action =
  let env = appEnv deps
   in runEff
        . runTracing (tracer env)
        . runErrorNoCallStack
        . runStorePool (store env)
        $ action

logSinkResult :: RunJob -> SinkResult -> IO ()
logSinkResult _job _result = pure ()
