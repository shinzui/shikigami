module Shikigami.Agent.Workflow
  ( AgentRunDeps (..),
    AgentRunHooks (..),
    defaultAgentRunHooks,
    agentRunWorkflowName,
    agentRunWorkflow,
    runAgentRunWorkflow,
    agentRunRegistry,
    PreparedSinkIntent,
    -- | The outboxed wire type. Exported so
    -- "Shikigami.WireCompatSpec" can pin its JSON encoding.
    SinkIntent (..),
    enqueueSinkIntentStep,
    enqueuePreparedSinkIntentTx,
    prepareSinkIntent,
    preparedSinkResult,
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
import Data.Time (NominalDiffTime, secondsToNominalDiffTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Transaction qualified as Tx
import Keiro.Integration.Event (IntegrationContentType (ApplicationJson), IntegrationEvent (..), decodeJsonIntegrationEvent, encodeJsonIntegrationEvent)
import Keiro.Outbox (OutboxId (..), OutboxMessage (..), OutboxRow (..), PublishOutcome (..), enqueueOutboxTx)
import Keiro.Workflow
  ( JournalAppendOutcome (..),
    StepName (..),
    Workflow,
    WorkflowId (..),
    WorkflowJournalEvent (StepRecorded),
    WorkflowOutcome,
    currentRunGeneration,
    currentWorkflow,
    prepareJournalAppend,
    runWorkflow,
    step,
  )
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Kioku.Api.Types (Confidence (MediumConfidence), MemoryRecord, MemoryType (MemoryPattern))
import Kioku.App (AppEffects, AppEnv (..))
import Kioku.Id (MemoryId, SessionId, genMemoryId, genSessionId, idText, parseId)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Session qualified as Session
import Kioku.Session.Domain (CompleteSessionData (..), FailSessionData (..), StartSessionData (..))
import Kiroku.Store.Effect (Store, runStoreResource)
import Kiroku.Store.Effect.Resource (withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import OpenTelemetry.Trace.Core qualified as Otel
import Shibuya.Telemetry.Effect (SpanArguments, SpanKind (..), addAttribute, runTracing, withSpan')
import Shikigami.Activity qualified as Activity
import Shikigami.Agent.Approval (ApprovalDecision (..), ApprovalEnv (..), ApprovalRequirement (..), awaitApproval)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Sink, Trigger (..))
import Shikigami.Agent.Delegate (awaitDelegated, delegate)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Run (AgentRunResult (..), behaviorKindText, recallPriorLearnings, recallQuery, renderLearning)
import Shikigami.Agent.RunJob (RunJob (..))
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.Behavior.Run (BehaviorEnv, BehaviorInput (..), behaviorModelId, runBehavior)
import Shikigami.Flow qualified as Flow
import Shikigami.Flow.Capability qualified as FlowCapability
import Shikigami.Log qualified as Log
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Prelude
import Shikigami.Program.Registry (codeResearcherTaskName, researchSupervisorTaskName, webResearcherTaskName)
import Shikigami.Sink (DanwaConfig, DanwaTarget, KawaConfig, KizashiConfig, ReiConfig, SinkContext (..), SinkOutcome (..), SinkResult (..), checkGrant, dispatch, sinkKindOf)
import Shikigami.Sink.Permission (AgentIdentity (AgentIdentity), Denied (..), sinkKindText)
import Shikigami.Sink.Recipient (resolveSinkRecipient)

data AgentRunDeps = AgentRunDeps
  { appEnv :: !AppEnv,
    behaviorEnv :: !BehaviorEnv,
    agents :: ![AgentDecl],
    kizashi :: !KizashiConfig,
    kawa :: !KawaConfig,
    danwa :: !DanwaConfig,
    rei :: !ReiConfig,
    hooks :: !AgentRunHooks,
    approval :: !(SessionId -> ApprovalEnv),
    deadline :: !(Maybe NominalDiffTime),
    -- | Where this run's log lines go. A workflow runs in whichever process
    -- picked the job up, so the logger arrives with the dependencies rather
    -- than being reached for globally.
    logger :: !Log.Logger
  }

data AgentRunHooks = AgentRunHooks
  { beforeStepBody :: !(StepName -> IO ()),
    afterStepBody :: !(StepName -> IO ())
  }

-- | What the outbox carries: everything the publisher needs to dispatch one sink
-- later, in a different process, after a restart.
--
-- __This record is duplicated__ in "Shikigami.Flow.SinkOutbox", which enqueues
-- the flow path's intents, because that module cannot import this one without a
-- cycle. 'publishSinkIntent' decodes both with /this/ type, so a field added to
-- one and not the other is silently dropped on the way out.
-- @Shikigami.WireCompatSpec@ asserts the two encoders agree; consolidating them
-- is @docs\/plans\/27-consolidate-the-sink-dispatch-and-delivery-machinery.md@.
--
-- Encoded with @omitNothingFields@ so that an intent carrying no optional values
-- is byte-identical to one written before those fields existed. That is what
-- makes adding a field here a genuine non-event for rows already sitting in a
-- database — see @Shikigami.WireCompatSpec@, which pins the pre-upgrade bytes.
data SinkIntent = SinkIntent
  { agent :: !Text,
    runId :: !Text,
    ordinal :: !Int,
    occurredAt :: !(Maybe UTCTime),
    danwaTarget :: !(Maybe DanwaTarget),
    -- | What the sink's @recipientFrom@ strategy resolved to, decided here
    -- because the trigger activity is only in scope on this side of the outbox.
    -- Absent on every row written before this field existed, which decodes as
    -- 'Nothing' and behaves exactly as it did then.
    resolvedRecipient :: !(Maybe Text),
    sink :: !Sink,
    output :: !Value
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SinkIntent where toJSON = genericToJSON sinkIntentOptions

instance FromJSON SinkIntent where parseJSON = genericParseJSON sinkIntentOptions

-- | Shared with "Shikigami.Flow.SinkOutbox"'s copy of the record; the two must
-- stay identical.
sinkIntentOptions :: Options
sinkIntentOptions = defaultOptions {omitNothingFields = True}

data PreparedSinkIntent = PreparedSinkIntent
  { sinkResult :: !SinkResult,
    outboxMessage :: !(Maybe OutboxMessage)
  }

defaultAgentRunHooks :: AgentRunHooks
defaultAgentRunHooks =
  AgentRunHooks
    { beforeStepBody = \_ -> pure (),
      afterStepBody = \_ -> pure ()
    }

agentDeclName :: AgentDecl -> Text
agentDeclName AgentDecl {name} = name

jobIdempotencyKey :: RunJob -> Text
jobIdempotencyKey RunJob {idempotencyKey} = idempotencyKey

-- | Named rather than used as a bare selector because 'SinkContext' also has a
-- @logger@ field, and @DuplicateRecordFields@ makes the unqualified use
-- ambiguous wherever both records are in scope.
depsLogger :: AgentRunDeps -> Log.Logger
depsLogger AgentRunDeps {logger = l} = l

runJobOccurredAt :: RunJob -> UTCTime
runJobOccurredAt RunJob {occurredAt} = occurredAt

agentRunWorkflow ::
  AgentRunDeps ->
  Maybe RunJob ->
  Eff (Workflow : AppEffects) (Either Text AgentRunResult)
agentRunWorkflow deps mJob = do
  job <- runStep deps (StepName "ingest-job") (ingestJob mJob)
  mDecl <- runStep deps (StepName "lookup-agent") (pure (find ((== agentName job) . agentDeclName) (agents deps)))
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
        . withKirokuStore (connectionSettings env)
        . runStoreResource
        $ runWorkflow
          agentRunWorkflowName
          (WorkflowId (jobIdempotencyKey job))
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
  withSpan' "trigger" (spanArgs Internal) \traceSpan -> do
    addAttribute traceSpan "agent.name" (agentName job)
    addAttribute traceSpan "trigger.kind" (triggerKindText (trigger decl))
    addAttribute traceSpan "run.idempotency_key" (jobIdempotencyKey job)
  sid <- runStep deps (StepName "open-session") (openSession deps job decl)
  prior <- runStep deps (StepName "recall") (liftIO (recallPriorLearnings (appEnv deps) (agentScope (agentDeclName decl)) (recallQuery decl (behaviorKindText (behavior decl)) (triggerPayload job))))
  behaviorE <-
    withSpan' "behavior" (spanArgs Internal) \traceSpan -> do
      addAttribute traceSpan "agent.name" (agentDeclName decl)
      addAttribute traceSpan "behavior.kind" (behaviorKindText (behavior decl))
      case behavior decl of
        Flow {} -> runBehaviorStep deps sid decl job prior
        _ -> runStep deps (StepName "run-behavior") (runBehaviorStep deps sid decl job prior)
  case behaviorE of
    Left err -> do
      _ <- runStep deps (StepName "fail-session") (failSession deps sid err)
      pure (Left err)
    Right output -> do
      approvedSinks <- approveSinks deps sid job decl output
      sinkResults <-
        withSpan' "sink.dispatch" (spanArgs Producer) \traceSpan -> do
          addAttribute traceSpan "agent.name" (agentDeclName decl)
          addAttribute traceSpan "sink.count" (length approvedSinks)
          enqueueSinkIntents job (decl {sinks = approvedSinks}) sid output
      liftIO (traverse_ (logSinkResult (depsLogger deps) job) sinkResults)
      mem <- runStep deps (StepName "record") (recordLearning deps decl sid output)
      _ <- runStep deps (StepName "complete") (completeSession deps sid)
      pure
        ( Right
            AgentRunResult
              { sessionId = sid,
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

openSession :: (IOE :> es) => AgentRunDeps -> RunJob -> AgentDecl -> Eff es SessionId
openSession deps job decl = liftIO do
  startedAt' <- getCurrentTime
  sid <- genSessionId
  let focusTxt = behaviorKindText (behavior decl)
      RunJob {parentSessionId = jobParentSessionId, delegationDepth = jobDelegationDepth} = job
  parsedParent <-
    case jobParentSessionId of
      Nothing -> pure Nothing
      Just raw ->
        case parseId raw of
          Right parsed -> pure (Just parsed)
          Left err -> ioError (userError ("invalid parentSessionId on RunJob: " <> Text.unpack err))
  _ <-
    Session.start
      StartSessionData
        { sessionId = sid,
          agentId = agentDeclName decl,
          focus = focusTxt,
          scope = agentScope (agentDeclName decl),
          subjectRef = Just (idText sid),
          previousSessionId = Nothing,
          parentSessionId = parsedParent,
          delegationDepth = fromMaybe 0 jobDelegationDepth,
          startedAt = startedAt'
        }
      & runKioku deps
  pure sid

-- | Run the declared behavior on the trigger payload and the memories the
-- @recall@ step returned.
--
-- @prior@ is the journaled result of @recall@, not a fresh fetch: a run resumed
-- after a crash replays the recorded list, so the behavior sees the same
-- memories the original attempt did. The step's name and result shape are
-- unchanged — only what the body is given.
runBehaviorStep ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  AgentRunDeps ->
  SessionId ->
  AgentDecl ->
  RunJob ->
  [MemoryRecord] ->
  Eff es (Either Text Value)
runBehaviorStep deps sid decl@AgentDecl {behavior = currentBehavior} job@RunJob {triggerPayload} prior =
  case currentBehavior of
    Flow {name = flowName} -> runFlowBehavior deps sid decl job flowName
    ShikumiProgram {task}
      | task == researchSupervisorTaskName -> Right <$> runResearchSupervisor sid job
    _ ->
      liftIO
        ( first (Text.pack . show)
            <$> runBehavior (behaviorEnv deps) decl BehaviorInput {payload = triggerPayload, recalled = prior}
        )

runFlowBehavior ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  AgentRunDeps ->
  SessionId ->
  AgentDecl ->
  RunJob ->
  Text ->
  Eff es (Either Text Value)
runFlowBehavior deps sid decl job flowName =
  case Flow.lookupFlow runtime flowName of
    Nothing -> pure (Left ("unknown flow " <> flowName))
    Just Flow.FlowDef {Flow.run} -> do
      output <-
        FlowCapability.runActivity (activityFromJob job)
          . FlowCapability.runMemory memoryEnv
          . FlowCapability.runSink sinkEnv
          $ run (triggerPayload job)
      pure (Right output)
  where
    runtime =
      Flow.FlowRuntime
        { Flow.approval = approval deps sid,
          Flow.acknowledgementDeadline = fromMaybe (secondsToNominalDiffTime 900) (deadline deps)
        }
    memoryEnv = FlowCapability.MemoryEnv {FlowCapability.appEnv = appEnv deps, FlowCapability.agent = decl, FlowCapability.sessionId = Just sid}
    sinkEnv =
      FlowCapability.SinkEnv
        { FlowCapability.agent = agentName job,
          FlowCapability.runId = idText sid,
          FlowCapability.occurredAt = Just (runJobOccurredAt job),
          FlowCapability.danwaTarget = Nothing,
          FlowCapability.activity = Just (activityFromJob job)
        }

activityFromJob :: RunJob -> Activity.ActivityEnvelope
activityFromJob job@RunJob {triggerPayload} =
  case Aeson.fromJSON triggerPayload of
    Aeson.Success activity -> activity
    Aeson.Error _ -> syntheticActivityFromJob job

syntheticActivityFromJob :: RunJob -> Activity.ActivityEnvelope
syntheticActivityFromJob RunJob {agentName, occurredAt, triggerPayload, idempotencyKey} =
  Activity.ActivityEnvelope
    { Activity.activityId = idempotencyKey,
      Activity.occurredAt = Text.pack (iso8601Show occurredAt),
      Activity.source = "shinzui/shikigami",
      Activity.actor = Activity.Actor {Activity.kind = "service", Activity.id = agentName, Activity.session = Nothing},
      Activity.subject = Activity.Subject {Activity.subjectType = "run", Activity.subjectId = idempotencyKey},
      Activity.verb = "run.triggered",
      Activity.payload = triggerPayload,
      Activity.contextRefs = [],
      Activity.idempotencyKey = idempotencyKey
    }

runResearchSupervisor ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  SessionId ->
  RunJob ->
  Eff es Value
runResearchSupervisor currentSession RunJob {triggerPayload, parentSessionId, parentRunWorkflowId, delegationDepth} = do
  let ctx =
        DelegateCtx
          { delegateDepth = fromMaybe 0 delegationDepth,
            sessionId = Just (idText currentSession),
            parentSessionId,
            parentRunWorkflowId
          }
      childPayload role =
        Aeson.object
          [ (Aeson..=) "role" role,
            (Aeson..=) "input" triggerPayload
          ]
  web <- delegate ctx webResearcherTaskName (childPayload ("web" :: Text))
  code <- delegate ctx codeResearcherTaskName (childPayload ("code" :: Text))
  webFinding <- awaitDelegated web
  codeFinding <- awaitDelegated code
  pure
    ( Aeson.object
        [ (Aeson..=) "summary" ("research-supervisor synthesized delegated findings" :: Text),
          (Aeson..=) "web" (webFinding :: Value),
          (Aeson..=) "code" (codeFinding :: Value)
        ]
    )

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
                    danwaTarget = Nothing,
                    -- Resolved here, not in the publisher: the trigger activity
                    -- is in scope on this side of the outbox and not the other.
                    resolvedRecipient = resolveSinkRecipient sink (Just (activityFromJob job)),
                    sink,
                    output
                  }
              messageId = sinkMessageId workflowId ordinal
              event = sinkIntentEvent messageId runIdText jobOccurredAt intent
              outboxId = deterministicOutboxId workflowId ordinal
           in (SinkResult kind (Delivered ("outbox:" <> messageId)), Just (OutboxMessage outboxId event))

enqueueSinkIntentStep ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  StepName ->
  Text ->
  Text ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Maybe Text ->
  Sink ->
  Value ->
  Eff es SinkResult
enqueueSinkIntentStep stepName agentName' runIdText ordinal occurredAt' danwaTarget' resolvedRecipient' sink output = do
  (workflowName, workflowId) <- currentWorkflow
  generation <- currentRunGeneration
  now <- liftIO getCurrentTime
  prepared <- liftIO (prepareSinkIntent workflowId stepName agentName' runIdText ordinal occurredAt' danwaTarget' resolvedRecipient' sink output now)
  let result = preparedSinkResult prepared
  appendTx <- prepareJournalAppend workflowName workflowId generation (StepRecorded (unStepName stepName) (Aeson.toJSON result) now)
  txResult <- runTransaction do
    appendTx >>= \case
      JournalAppended {} -> do
        enqueuePreparedSinkIntentTx prepared
        pure (Right result)
      JournalAlreadyPresent stored ->
        case parseEither Aeson.parseJSON stored of
          Right replayed -> pure (Right replayed)
          Left err -> pure (Left ("sink intent replay decode failed: " <> Text.pack err))
      JournalAppendConflict err ->
        pure (Left ("sink intent journal append conflict: " <> Text.pack (show err)))
  case txResult of
    Right result' -> pure result'
    Left err -> liftIO (ioError (userError (Text.unpack err)))

prepareSinkIntent ::
  WorkflowId ->
  StepName ->
  Text ->
  Text ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Maybe Text ->
  Sink ->
  Value ->
  UTCTime ->
  IO PreparedSinkIntent
prepareSinkIntent workflowId stepName agentName' runIdText ordinal occurredAt' danwaTarget' resolvedRecipient' sink output now = do
  let kind = sinkKindOf sink
      messageId = unWorkflowId workflowId <> ":" <> unStepName stepName
      outboxId = deterministicOutboxIdForMessage messageId
      deniedResult reason = SinkResult kind (DeniedOutcome reason)
      deliveredResult = SinkResult kind (Delivered ("outbox:" <> messageId))
  checkGrant (AgentIdentity agentName') kind <&> \case
    Left (Denied reason) ->
      PreparedSinkIntent
        { sinkResult = deniedResult reason,
          outboxMessage = Nothing
        }
    Right () ->
      let intent =
            SinkIntent
              { agent = agentName',
                runId = runIdText,
                ordinal,
                occurredAt = occurredAt',
                danwaTarget = danwaTarget',
                resolvedRecipient = resolvedRecipient',
                sink,
                output
              }
          event = sinkIntentEvent messageId runIdText now intent
       in PreparedSinkIntent
            { sinkResult = deliveredResult,
              outboxMessage = Just (OutboxMessage outboxId event)
            }

preparedSinkResult :: PreparedSinkIntent -> SinkResult
preparedSinkResult PreparedSinkIntent {sinkResult} = sinkResult

enqueuePreparedSinkIntentTx :: PreparedSinkIntent -> Tx.Transaction ()
enqueuePreparedSinkIntentTx PreparedSinkIntent {outboxMessage} =
  traverse_ enqueueOutboxTx outboxMessage

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
  deterministicOutboxIdForMessage (sinkMessageId workflowId ordinal)

deterministicOutboxIdForMessage :: Text -> OutboxId
deterministicOutboxIdForMessage messageId =
  OutboxId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      fmap (fromIntegral . fromEnum) $
        Text.unpack ("shikigami:sink:" <> messageId)

publishSinkIntent :: (IOE :> es) => AgentRunDeps -> OutboxRow -> Eff es PublishOutcome
publishSinkIntent AgentRunDeps {kizashi = depsKizashi, kawa = depsKawa, danwa = depsDanwa, rei = depsRei, logger = intentLogger} row =
  let OutboxRow {event = integrationEvent} = row
   in case decodeJsonIntegrationEvent integrationEvent of
        Left err -> pure (PublishFailed (Text.pack (show err)))
        Right SinkIntent {agent, runId, ordinal, occurredAt, danwaTarget, resolvedRecipient, sink, output} -> liftIO do
          result <-
            dispatch
              SinkContext
                { identity = AgentIdentity agent,
                  runId = runId,
                  ordinal = ordinal,
                  kizashi = depsKizashi,
                  kawa = depsKawa,
                  danwa = depsDanwa,
                  rei = depsRei,
                  danwaTarget = danwaTarget,
                  recipientOverride = resolvedRecipient,
                  occurredAt = occurredAt,
                  logger = intentLogger
                }
              sink
              output
          pure $ case outcome result of
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
          agentId = agentDeclName decl,
          sessionId = Just sid,
          scope = agentScope (agentDeclName decl),
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

-- | Close the kioku session, recording which model produced its output.
--
-- @modelUsed@ is the durable answer to \"was this a real run?\". A stub run
-- records @stub-v1@ and a real one records the upstream model id, so a session
-- read back weeks later says what answered it — which the startup log, belonging
-- to a process that has since restarted, cannot.
--
-- This changes what the @complete@ step body writes, not the journal: the step
-- name and its recorded result shape are untouched, so a workflow parked before
-- this change still replays.
completeSession :: (IOE :> es) => AgentRunDeps -> SessionId -> Eff es ()
completeSession deps sid = liftIO do
  completedAt' <- getCurrentTime
  void $
    Session.complete
      CompleteSessionData
        { sessionId = sid,
          completedAt = completedAt',
          modelUsed = Just (behaviorModelId (behaviorEnv deps)),
          summary = Just "agent-run completed"
        }
      & runKioku deps

runKioku :: AgentRunDeps -> Eff AppEffects a -> IO (Either StoreError a)
runKioku deps action =
  let env = appEnv deps
   in runEff
        . runTracing (tracer env)
        . runErrorNoCallStack
        . withKirokuStore (connectionSettings env)
        . runStoreResource
        $ action

-- | Say what one sink actually did.
--
-- This was a no-op (@logSinkResult _job _result = pure ()@), which meant per-sink
-- outcomes were recorded in the workflow journal and nowhere an operator could
-- see them. Now every dispatched sink leaves one @sink.result@ line carrying the
-- agent, the run, the sink kind, and the outcome.
--
-- A failure logs at 'Log.Error' and a denial at 'Log.Warn', because those are the
-- two an operator wants to find without reading the successes.
logSinkResult :: Log.Logger -> RunJob -> SinkResult -> IO ()
logSinkResult logger job result =
  Log.logEvent
    logger
    (levelFor (outcome result))
    "sink.result"
    ( [ "agent" Aeson..= agentName job,
        Log.runIdKey Aeson..= jobIdempotencyKey job,
        "sink_kind" Aeson..= sinkKindText (kind result),
        "outcome" Aeson..= outcomeText (outcome result)
      ]
        <> detailField (outcome result)
    )
  where
    levelFor = \case
      Failed _ -> Log.Error
      DeniedOutcome _ -> Log.Warn
      _ -> Log.Info
    outcomeText :: SinkOutcome -> Text
    outcomeText = \case
      Delivered _ -> "delivered"
      Stubbed -> "stubbed"
      DeniedOutcome _ -> "denied"
      Failed _ -> "failed"
    -- The detail rides under a key that says what kind of detail it is, so that
    -- a query for failures can read @error@ without also matching the returned
    -- id of a successful delivery.
    detailField = \case
      Delivered detail -> ["detail" Aeson..= detail]
      Stubbed -> []
      DeniedOutcome reason -> ["reason" Aeson..= reason]
      Failed err -> ["error" Aeson..= err]

triggerKindText :: Trigger -> Text
triggerKindText = \case
  Schedule {} -> "schedule"
  Stream {} -> "stream"
  Event {} -> "event"

spanArgs :: SpanKind -> SpanArguments
spanArgs spanKind =
  Otel.defaultSpanArguments {Otel.kind = spanKind}
