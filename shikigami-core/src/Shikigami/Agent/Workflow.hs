module Shikigami.Agent.Workflow
  ( AgentRunDeps (..),
    AgentRunFailure (..),
    agentRunFailureDetail,
    -- | The journaled step value that carries a kioku refusal. Exported so
    -- "Shikigami.WireCompatSpec" can pin that a produced value still encodes as
    -- the bare value the step wrote before this shape existed.
    StepResult (..),
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
    permanentPublishOutcome,
    publishSinkIntent,
    reconcilePublishedSinkIntent,
  )
where

import Data.Aeson (Key, Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
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
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError_)
import Hasql.Pool (Pool)
import Hasql.Transaction qualified as Tx
import Keiro.Integration.Event (IntegrationContentType (ApplicationJson), IntegrationEvent (..), decodeJsonIntegrationEvent, encodeJsonIntegrationEvent)
import Keiro.Integration.Event qualified as Integration
import Keiro.Outbox (OutboxId (..), OutboxMessage (..), OutboxRow (..), PublishOutcome (..), enqueueOutboxTx, mkPublishRejection)
import Keiro.Workflow
  ( JournalAppendOutcome (..),
    PatchId (..),
    StepName (..),
    Workflow,
    WorkflowId (..),
    WorkflowJournalEvent (StepRecorded),
    WorkflowOutcome,
    currentRunGeneration,
    currentWorkflow,
    patch,
    prepareJournalAppend,
    runWorkflowWith,
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
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), DelegationBudget, IdentityDecl (..), MemoryPolicy (..), ProfileRequirement (..), RecordPolicy (..), Sink, Trigger (..))
import Shikigami.Agent.Delegate (awaitAllDelegated, delegate)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Run (AgentRunResult (..), behaviorKindText, recallPriorLearnings, recallQuery, renderLearning)
import Shikigami.Agent.RunFailure (AgentRunFailure (..), agentRunFailureDetail)
import Shikigami.Agent.RunJob (RunJob (..))
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName, ingestJobStepName)
import Shikigami.Attestation.Profile (ProfileId (..), ProfileVersion (..))
import Shikigami.Attestation.Resolve (ProfileResolutionError, ResolvedProfile, renderProfileResolutionError)
import Shikigami.Behavior.Provider (ProfileViolation, constrainBehaviorEnv, renderProfileViolation)
import Shikigami.Behavior.Run (BehaviorEnv, BehaviorInput (..), behaviorModelId, runBehavior, runBehaviorAttempt)
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Directory qualified as Directory
import Shikigami.Flow qualified as Flow
import Shikigami.Flow.Acknowledgement (runAcknowledgement)
import Shikigami.Flow.Capability qualified as FlowCapability
import Shikigami.Flow.Delegate qualified as FlowDelegate
import Shikigami.Id.Name (nameBytes)
import Shikigami.Log qualified as Log
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Prelude
import Shikigami.Sink (DanwaConfig, DanwaTarget, DeliveryGuard (..), GrantSource, KawaConfig, KizashiConfig, ReiConfig, SinkContext (..), SinkOutcome (..), SinkResult (..), checkGrant, dispatch, sinkKindOf)
import Shikigami.Sink.Delivery qualified as Delivery
import Shikigami.Sink.Permission (AgentIdentity (AgentIdentity), Denied (..), SinkKind, sinkKindText)
import Shikigami.Sink.Recipient (resolveSinkRecipient)
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)

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
    runTimeout :: !NominalDiffTime,
    -- | Root-run descendant limit used when an agent declaration leaves its
    -- own delegation budget absent.
    delegationBudget :: !DelegationBudget,
    -- | Which grant source the enqueue-time C11 check consults, and the one
    -- handed to every 'SinkContext' this run builds.
    grants :: !GrantSource,
    -- | Cached principal lifecycle and attribution view shared with trigger and
    -- drain gates.
    directory :: !DirectoryHandle,
    -- | The Shikigami receipt store used only by the asynchronous publisher.
    -- Production always supplies it; focused workflow tests may opt out because
    -- they never cross the publisher boundary.
    deliveryPool :: !(Maybe Pool),
    -- | Where this run's log lines go. A workflow runs in whichever process
    -- picked the job up, so the logger arrives with the dependencies rather
    -- than being reached for globally.
    logger :: !Log.Logger,
    -- | Resolve the profile named by an agent declaration. A function seam
    -- keeps the durable workflow independent of PostgreSQL and lets replay tests
    -- prove exactly how often resolution executed.
    resolveRunProfile ::
      !(ProfileId -> Maybe ProfileVersion -> IO (Either ProfileResolutionError ResolvedProfile))
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
    principalId :: !(Maybe Text),
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
    outboxMessage :: !(Maybe OutboxMessage),
    deliveryReceipt :: !(Maybe Delivery.DeliveryReceipt)
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

-- | Named for the same reason as 'depsLogger': 'SinkContext' and
-- 'FlowCapability.SinkEnv' also carry a @grants@ field.
depsGrants :: AgentRunDeps -> GrantSource
depsGrants AgentRunDeps {grants = g} = g

depsDirectory :: AgentRunDeps -> DirectoryHandle
depsDirectory AgentRunDeps {directory = value} = value

declaredPrincipalId :: AgentDecl -> Maybe Text
declaredPrincipalId AgentDecl {identity} = declared <$> identity
  where
    declared IdentityDecl {principal} = principal

depsRunTimeout :: AgentRunDeps -> NominalDiffTime
depsRunTimeout AgentRunDeps {runTimeout = timeout} = timeout

depsDelegationBudget :: AgentRunDeps -> DelegationBudget
depsDelegationBudget AgentRunDeps {delegationBudget = value} = value

declDelegationBudget :: AgentDecl -> Maybe DelegationBudget
declDelegationBudget AgentDecl {delegationBudget = value} = value

runJobOccurredAt :: RunJob -> UTCTime
runJobOccurredAt RunJob {occurredAt} = occurredAt

agentRunWorkflow ::
  AgentRunDeps ->
  Maybe RunJob ->
  Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult)
agentRunWorkflow deps mJob = do
  job <- runStep deps ingestJobStepName (ingestJob mJob)
  mDecl <- runStep deps (StepName "lookup-agent") (pure (find ((== agentName job) . agentDeclName) (agents deps)))
  case mDecl of
    Nothing -> pure (Left (PermanentAgentRunFailure ("unknown agent " <> agentName job)))
    Just decl -> runResolvedAgent deps job decl

runAgentRunWorkflow ::
  AgentRunDeps ->
  RunJob ->
  IO (Either StoreError (WorkflowOutcome (Either AgentRunFailure AgentRunResult)))
runAgentRunWorkflow deps job =
  let env = appEnv deps
   in runEff
        . runTracing (tracer env)
        . runErrorNoCallStack
        . withKirokuStore (connectionSettings env)
        . runStoreResource
        $ runWorkflowWith
          shikigamiWorkflowRunOptions
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
  Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult)
runResolvedAgent deps job decl = do
  resolveProfileForRun <- patch profileResolutionPatch
  profileResolution <-
    if resolveProfileForRun
      then
        runStep
          deps
          (StepName "resolve-profile")
          (liftIO (resolveRequiredProfile deps decl))
      else pure (Right Nothing)
  case profileResolution of
    Left refusal -> pure (Left (PermanentAgentRunFailure (renderProfileResolutionError refusal)))
    Right resolvedProfile -> runProfiledAgent deps job decl resolvedProfile

profileResolutionPatch :: PatchId
profileResolutionPatch = PatchId "shikigami-resolve-profile-v1"

runProfiledAgent ::
  AgentRunDeps ->
  RunJob ->
  AgentDecl ->
  Maybe ResolvedProfile ->
  Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult)
runProfiledAgent deps job decl resolvedProfile =
  case behaviorEnvForProfile decl resolvedProfile (behaviorEnv deps) of
    Left violation -> pure (Left (PermanentAgentRunFailure (renderProfileViolation violation)))
    Right activeBehaviorEnv -> runProfiledAgentWith deps activeBehaviorEnv job decl

behaviorEnvForProfile ::
  AgentDecl ->
  Maybe ResolvedProfile ->
  BehaviorEnv ->
  Either ProfileViolation BehaviorEnv
behaviorEnvForProfile AgentDecl {behavior = Skill {}} (Just resolvedProfile) =
  constrainBehaviorEnv resolvedProfile
behaviorEnvForProfile _decl _resolvedProfile = Right

runProfiledAgentWith ::
  AgentRunDeps ->
  BehaviorEnv ->
  RunJob ->
  AgentDecl ->
  Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult)
runProfiledAgentWith deps activeBehaviorEnv job decl = do
  withSpan' "trigger" (spanArgs Internal) \traceSpan -> do
    addAttribute traceSpan "agent.name" (agentName job)
    addAttribute traceSpan "trigger.kind" (triggerKindText (trigger decl))
    addAttribute traceSpan "run.idempotency_key" (jobIdempotencyKey job)
  opened <- runStep deps (StepName "open-session") (requireStore (openSession deps job decl))
  case opened of
    -- kioku refused to open the session. The same command will be refused on
    -- every replay, so there is nothing to retry and the run is over.
    StepRefused detail -> pure (Left (PermanentAgentRunFailure detail))
    StepProduced sid -> runSessionedAgent deps activeBehaviorEnv job decl sid

-- | The rest of one agent run, once its kioku session is open.
runSessionedAgent ::
  AgentRunDeps ->
  BehaviorEnv ->
  RunJob ->
  AgentDecl ->
  SessionId ->
  Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult)
runSessionedAgent deps activeBehaviorEnv job decl@AgentDecl {memory = MemoryPolicy {recallLimit = declaredRecallLimit}} sid = do
  prior <- runStep deps (StepName "recall") (liftIO (recallPriorLearnings (appEnv deps) declaredRecallLimit (agentScope (agentDeclName decl)) (recallQuery decl (behaviorKindText (behavior decl)) (triggerPayload job))))
  useRetrySemantics <- patch behaviorRetryPatch
  behaviorE <-
    withSpan' "behavior" (spanArgs Internal) \traceSpan -> do
      addAttribute traceSpan "agent.name" (agentDeclName decl)
      addAttribute traceSpan "behavior.kind" (behaviorKindText (behavior decl))
      case behavior decl of
        Flow {} -> first PermanentAgentRunFailure <$> runBehaviorStep deps activeBehaviorEnv sid decl job prior
        _
          | not (null (delegates decl)) ->
              first PermanentAgentRunFailure <$> runBehaviorStep deps activeBehaviorEnv sid decl job prior
          | useRetrySemantics ->
              first PermanentAgentRunFailure
                <$> runStep
                  deps
                  (StepName "run-behavior-v2")
                  ( liftIO
                      ( runBehaviorAttempt
                          (depsRunTimeout deps)
                          activeBehaviorEnv
                          decl
                          BehaviorInput {payload = triggerPayload job, recalled = prior}
                      )
                  )
          | otherwise ->
              first LegacyBehaviorFailure
                <$> runStep deps (StepName "run-behavior") (runBehaviorStep deps activeBehaviorEnv sid decl job prior)
  case behaviorE of
    Left err -> do
      failed <- runStep deps (StepName "fail-session") (requireStore (failSession deps decl sid (agentRunFailureDetail err)))
      pure case failed of
        StepProduced () -> Left err
        -- The run failed either way; if the failure could not be recorded, say
        -- both things rather than only the half that reached a store.
        StepRefused detail ->
          Left
            ( PermanentAgentRunFailure
                (agentRunFailureDetail err <> " (and " <> detail <> ")")
            )
    Right output -> do
      approvedSinks <- approveSinks deps sid job decl output
      sinkResults <-
        withSpan' "sink.dispatch" (spanArgs Producer) \traceSpan -> do
          addAttribute traceSpan "agent.name" (agentDeclName decl)
          addAttribute traceSpan "sink.count" (length approvedSinks)
          enqueueSinkIntents (depsDirectory deps) (depsGrants deps) job (decl {sinks = approvedSinks}) sid output
      liftIO (traverse_ (logSinkResult (depsLogger deps) job) sinkResults)
      recorded <- runStep deps (StepName "record") (requireStore (recordLearning deps decl sid output))
      case recorded of
        StepRefused detail -> pure (Left (PermanentAgentRunFailure detail))
        StepProduced mem -> do
          completed <- runStep deps (StepName "complete") (requireStore (completeSession deps activeBehaviorEnv decl sid))
          pure case completed of
            StepRefused detail -> Left (PermanentAgentRunFailure detail)
            StepProduced () ->
              Right
                AgentRunResult
                  { sessionId = sid,
                    recalledPrior = prior,
                    behaviorOutput = output,
                    recordedMemId = mem
                  }

behaviorRetryPatch :: PatchId
behaviorRetryPatch = PatchId "shikigami-behavior-retry-v1"

resolveRequiredProfile ::
  AgentRunDeps ->
  AgentDecl ->
  IO (Either ProfileResolutionError (Maybe ResolvedProfile))
resolveRequiredProfile deps AgentDecl {sanctionedProfile} =
  case sanctionedProfile of
    Nothing -> pure (Right Nothing)
    Just ProfileRequirement {profileId, version} ->
      fmap Just
        <$> resolveRunProfile
          deps
          (ProfileId profileId)
          (ProfileVersion <$> version)

-- | A journaled step value that may record a refusal instead of a result.
--
-- Kioku answers a write on two layers, and they mean different things. The outer
-- @Either StoreError@ says whether the store could be reached at all; the inner
-- @Either SessionWriteError@ (or @MemoryWriteError@) says whether the store
-- accepted the command. A transport failure is retryable and is never journaled
-- — 'requireStore' rethrows it. A refusal is not retryable: the same command
-- built from the same job will be refused on every replay, so it belongs in the
-- journal as what that step actually answered.
--
-- Per [ADR 0011](docs\/adr\/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md)
-- an additive shape must leave the previous bytes untouched, so 'StepProduced'
-- encodes as the bare value exactly as these steps already wrote it, and only
-- 'StepRefused' introduces a key. That holds as long as @a@ never encodes as an
-- object carrying @stepRefused@; the three uses here encode as a string, a
-- string-or-null, and an empty array.
data StepResult a
  = StepProduced !a
  | StepRefused !Text
  deriving stock (Eq, Show, Functor)

instance (ToJSON a) => ToJSON (StepResult a) where
  toJSON = \case
    StepProduced value -> Aeson.toJSON value
    StepRefused detail -> Aeson.object [stepRefusedKey Aeson..= detail]

instance (FromJSON a) => FromJSON (StepResult a) where
  parseJSON value = case value of
    Aeson.Object fields
      | Just refusal <- KeyMap.lookup stepRefusedKey fields -> StepRefused <$> Aeson.parseJSON refusal
    _ -> StepProduced <$> Aeson.parseJSON value

stepRefusedKey :: Key
stepRefusedKey = "stepRefused"

-- | Classify one kioku write's two answers into the one journaled value.
kiokuWrite :: (Show e) => Text -> IO (Either StoreError (Either e a)) -> IO (Either StoreError (StepResult a))
kiokuWrite what written =
  written >>= \case
    Left storeError -> pure (Left storeError)
    Right (Left refusal) -> pure (Right (StepRefused (what <> " was refused: " <> Text.pack (show refusal))))
    Right (Right value) -> pure (Right (StepProduced value))

-- | Fail the run rather than journal a step that did not happen.
--
-- When the store cannot be reached nothing durable was written, so there is no
-- honest value to journal for that step. Rethrowing into the workflow driver's
-- 'Error' 'StoreError' — which 'runAgentRunWorkflow' already runs outside
-- 'runWorkflowWith' — surfaces the failure as its @Left storeError@, which the
-- run-job worker's outcome table already maps to a retry. The alternative,
-- discarding the result, is what let a run report success having opened no
-- session and persisted no memory.
requireStore :: (Error StoreError :> es) => Eff es (Either StoreError a) -> Eff es a
requireStore action = action >>= either throwError_ pure

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

-- | Open the run's kioku session.
--
-- Neither of kioku's two answers is discarded any more. A run whose session was
-- never opened has no durable record to attach memories or a completion to, and
-- reporting success for it is a lie about what happened: an unreachable store
-- becomes the workflow driver's retryable store-error arm, and a refused command
-- becomes a journaled 'StepRefused' the caller turns into a permanent failure.
openSession :: (IOE :> es) => AgentRunDeps -> RunJob -> AgentDecl -> Eff es (Either StoreError (StepResult SessionId))
openSession deps job decl = liftIO do
  startedAt' <- getCurrentTime
  sid <- genSessionId
  sessionAgentId <- Directory.principalAttribution (depsDirectory deps) (declaredPrincipalId decl) (agentDeclName decl)
  let focusTxt = behaviorKindText (behavior decl)
      RunJob {parentSessionId = jobParentSessionId, delegationDepth = jobDelegationDepth} = job
  parsedParent <-
    case jobParentSessionId of
      Nothing -> pure Nothing
      Just raw ->
        case parseId raw of
          Right parsed -> pure (Just parsed)
          Left err -> ioError (userError ("invalid parentSessionId on RunJob: " <> Text.unpack err))
  -- kioku answers with the session id it started, which is the one generated
  -- above; taking it from the answer keeps the step value the store's word.
  kiokuWrite "opening the run's kioku session" $
    Session.start
      StartSessionData
        { sessionId = sid,
          memorySpaceId = shikigamiMemorySpace,
          actorPrincipal = agentActor (agentDeclName decl),
          ownerPrincipal = Nothing,
          agentId = sessionAgentId,
          focus = focusTxt,
          scope = agentScope (agentDeclName decl),
          subjectRef = Just (idText sid),
          previousSessionId = Nothing,
          parentSessionId = parsedParent,
          delegationDepth = fromMaybe 0 jobDelegationDepth,
          startedAt = startedAt'
        }
      & runKioku deps

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
  BehaviorEnv ->
  SessionId ->
  AgentDecl ->
  RunJob ->
  [MemoryRecord] ->
  Eff es (Either Text Value)
runBehaviorStep deps activeBehaviorEnv sid decl@AgentDecl {behavior = currentBehavior} job@RunJob {triggerPayload} prior =
  case currentBehavior of
    Flow {name = flowName} -> runFlowBehavior deps sid decl job flowName
    _
      | not (null (delegates decl)) -> Right <$> runDeclaredSupervisor deps decl sid job
      | otherwise ->
          liftIO
            ( first (Text.pack . show)
                <$> runBehavior activeBehaviorEnv decl BehaviorInput {payload = triggerPayload, recalled = prior}
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
  case Flow.lookupFlow flowName of
    Nothing -> pure (Left ("unknown flow " <> flowName))
    Just Flow.FlowDef {Flow.run} -> do
      output <-
        FlowCapability.runActivity (activityFromJob job)
          . FlowCapability.runMemory memoryEnv
          . FlowCapability.runSink sinkEnv
          . FlowDelegate.runDelegate delegateEnv
          . runAcknowledgement (approval deps sid) (fromMaybe (secondsToNominalDiffTime 900) (deadline deps))
          $ run (triggerPayload job)
      pure (Right output)
  where
    memoryEnv = FlowCapability.MemoryEnv {FlowCapability.appEnv = appEnv deps, FlowCapability.agent = decl, FlowCapability.sessionId = Just sid}
    delegateEnv = FlowDelegate.DelegateEnv {FlowDelegate.agent = decl, FlowDelegate.context = delegateContext deps decl sid job}
    sinkEnv =
      FlowCapability.SinkEnv
        { FlowCapability.agent = agentName job,
          FlowCapability.runId = idText sid,
          FlowCapability.occurredAt = Just (runJobOccurredAt job),
          FlowCapability.danwaTarget = Nothing,
          FlowCapability.activity = Just (activityFromJob job),
          FlowCapability.grants = depsGrants deps,
          FlowCapability.directory = depsDirectory deps,
          FlowCapability.principalId = declaredPrincipalId decl
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

runDeclaredSupervisor ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  AgentRunDeps ->
  AgentDecl ->
  SessionId ->
  RunJob ->
  Eff es Value
runDeclaredSupervisor deps decl@AgentDecl {delegates = delegateTargets} currentSession job@RunJob {triggerPayload} = do
  let ctx = delegateContext deps decl currentSession job
      delegationKey ordinal = "delegate-" <> Text.pack (show ordinal)
      resultLabel target = fromMaybe target (Text.stripSuffix "-researcher" target)
      childPayload target =
        Aeson.object
          [ (Aeson..=) "role" (resultLabel target),
            (Aeson..=) "input" triggerPayload
          ]
  childHandles <-
    traverse
      (\(ordinal, target) -> delegate decl ctx (delegationKey ordinal) target (childPayload target))
      (zip [(0 :: Int) ..] delegateTargets)
  findings <- awaitAllDelegated childHandles
  pure
    ( Aeson.object
        ( (Aeson..=) "summary" (agentDeclName decl <> " synthesized delegated findings")
            : zipWith
              (\target finding -> (Aeson..=) (Key.fromText (resultLabel target)) (either Aeson.String id finding))
              delegateTargets
              findings
        )
    )

delegateContext :: AgentRunDeps -> AgentDecl -> SessionId -> RunJob -> DelegateCtx
delegateContext deps decl currentSession RunJob {agentName, parentSessionId, parentRunWorkflowId, delegationDepth, lineage, delegationBudgetId} =
  DelegateCtx
    { delegateDepth = fromMaybe 0 delegationDepth,
      sessionId = Just (idText currentSession),
      parentSessionId,
      parentRunWorkflowId,
      lineage = if null lineage then [agentName] else lineage,
      delegationBudgetId,
      budgetLimit = fromMaybe (depsDelegationBudget deps) (declDelegationBudget decl)
    }

-- | Mark the run's session failed, after one best-effort learning write.
--
-- The two writes are deliberately different in kind. Marking the session failed
-- is truth-bearing: a run that reports a failure it never recorded leaves a
-- session open forever and tells nobody. The learning write above it is the one
-- genuinely optional write on this path — the run has already failed, and losing
-- a note about /why/ does not make the recorded outcome wrong — so it is named
-- for what it is and says so when it fails rather than vanishing.
failSession :: (IOE :> es) => AgentRunDeps -> AgentDecl -> SessionId -> Text -> Eff es (Either StoreError (StepResult ()))
failSession deps decl@AgentDecl {memory = MemoryPolicy {recordPolicy}} sid err = liftIO do
  when (recordPolicy == Always) $
    recordFailureLearningBestEffort deps decl sid err
  failedAt' <- getCurrentTime
  kiokuWrite "marking the run's kioku session failed" $
    (fmap . fmap) void $
      Session.failSession
        FailSessionData
          { sessionId = sid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor (agentDeclName decl),
            failedAt = failedAt',
            errorMessage = err
          }
        & runKioku deps

-- | Write the "why did this run fail" learning, and carry on if the store will
-- not take it.
--
-- Named @BestEffort@ because that is the whole contract: the caller is already
-- on the failure path and must still mark the session failed, so this write may
-- not decide the run's outcome. What it may not do is disappear, which is what
-- the discarded result before it did.
recordFailureLearningBestEffort :: AgentRunDeps -> AgentDecl -> SessionId -> Text -> IO ()
recordFailureLearningBestEffort deps decl sid err = do
  recorded <-
    recordMemory
      deps
      decl
      sid
      ("run failed: " <> err)
      (Set.fromList ["agent-run", "failure"])
  case recorded of
    Right (StepProduced _) -> pure ()
    Right (StepRefused detail) -> bestEffortFailed detail
    Left storeError -> bestEffortFailed (Text.pack (show storeError))
  where
    bestEffortFailed detail =
      Log.logError
        (depsLogger deps)
        "agent.memory.best_effort_failed"
        [ "agent" Aeson..= agentDeclName decl,
          "write" Aeson..= ("failure_learning" :: Text),
          "error" Aeson..= detail
        ]

enqueueSinkIntents ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  DirectoryHandle ->
  GrantSource ->
  RunJob ->
  AgentDecl ->
  SessionId ->
  Value ->
  Eff es [SinkResult]
enqueueSinkIntents directoryHandle grantSource job decl sid output = do
  (workflowName, workflowId) <- currentWorkflow
  generation <- currentRunGeneration
  now <- liftIO getCurrentTime
  prepared <- liftIO (traverse (buildSinkIntent workflowId now) (zip [0 ..] (sinks decl)))
  let results = fst <$> prepared
      enqueued = mapMaybe snd prepared
      encoded = Aeson.toJSON results
  appendTx <- prepareJournalAppend workflowName workflowId generation (StepRecorded (unStepName dispatchSinksStep) encoded now)
  txResult <- runTransaction do
    appendTx >>= \case
      JournalAppended {} -> do
        traverse_ (enqueueOutboxTx . fst) enqueued
        traverse_ (Delivery.recordDeliveryTx . snd) enqueued
        pure (Right results)
      JournalAlreadyPresent stored ->
        case parseEither Aeson.parseJSON stored of
          Right replayed -> pure (Right replayed)
          Left err -> pure (Left ("dispatch-sinks replay decode failed: " <> Text.pack err))
      JournalRefusedTerminal marker ->
        pure (Left ("dispatch-sinks journal append refused by terminal marker: " <> marker))
      JournalAppendConflict err ->
        pure (Left ("dispatch-sinks journal append conflict: " <> Text.pack (show err)))
  case txResult of
    Right results' -> pure results'
    Left err -> liftIO (ioError (userError (Text.unpack err)))
  where
    dispatchSinksStep = StepName "dispatch-sinks"
    runIdText = idText sid

    buildSinkIntent workflowId now (ordinal, sink) = do
      let RunJob {occurredAt = jobOccurredAt} = job
      let kind = sinkKindOf sink
      Directory.lifecycleAdmission directoryHandle (declaredPrincipalId decl) (agentName job) >>= \case
        Left reason -> pure (SinkResult kind (SkippedLifecycle reason), Nothing)
        Right resolvedPrincipalId ->
          checkGrant grantSource (AgentIdentity (agentName job)) kind <&> \case
            Left (Denied reason) ->
              (SinkResult kind (DeniedOutcome reason), Nothing)
            Right () ->
              let intent =
                    SinkIntent
                      { agent = agentName job,
                        principalId = resolvedPrincipalId,
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
                  orderingKey = runIdText <> ":" <> Text.pack (show ordinal)
                  event = sinkIntentEvent messageId orderingKey jobOccurredAt intent
                  outboxId = deterministicOutboxId workflowId ordinal
                  receipt = pendingDeliveryReceipt messageId kind now intent
               in (SinkResult kind (Enqueued ("outbox:" <> messageId)), Just (OutboxMessage outboxId event, receipt))

enqueueSinkIntentStep ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  DirectoryHandle ->
  GrantSource ->
  Maybe Text ->
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
enqueueSinkIntentStep directoryHandle grantSource declaredPrincipalId' stepName agentName' runIdText ordinal occurredAt' danwaTarget' resolvedRecipient' sink output = do
  (workflowName, workflowId) <- currentWorkflow
  generation <- currentRunGeneration
  now <- liftIO getCurrentTime
  prepared <- liftIO (prepareSinkIntent directoryHandle grantSource declaredPrincipalId' workflowId stepName agentName' runIdText ordinal occurredAt' danwaTarget' resolvedRecipient' sink output now)
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
      JournalRefusedTerminal marker ->
        pure (Left ("sink intent journal append refused by terminal marker: " <> marker))
      JournalAppendConflict err ->
        pure (Left ("sink intent journal append conflict: " <> Text.pack (show err)))
  case txResult of
    Right result' -> pure result'
    Left err -> liftIO (ioError (userError (Text.unpack err)))

prepareSinkIntent ::
  DirectoryHandle ->
  GrantSource ->
  Maybe Text ->
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
prepareSinkIntent directoryHandle grantSource declaredPrincipalId' workflowId stepName agentName' runIdText ordinal occurredAt' danwaTarget' resolvedRecipient' sink output now = do
  let kind = sinkKindOf sink
      messageId = unWorkflowId workflowId <> ":" <> unStepName stepName
      outboxId = deterministicOutboxIdForMessage messageId
      deniedResult reason = SinkResult kind (DeniedOutcome reason)
      enqueuedResult = SinkResult kind (Enqueued ("outbox:" <> messageId))
  Directory.lifecycleAdmission directoryHandle declaredPrincipalId' agentName' >>= \case
    Left reason ->
      pure
        PreparedSinkIntent
          { sinkResult = SinkResult kind (SkippedLifecycle reason),
            outboxMessage = Nothing,
            deliveryReceipt = Nothing
          }
    Right resolvedPrincipalId ->
      checkGrant grantSource (AgentIdentity agentName') kind <&> \case
        Left (Denied reason) ->
          PreparedSinkIntent
            { sinkResult = deniedResult reason,
              outboxMessage = Nothing,
              deliveryReceipt = Nothing
            }
        Right () ->
          let intent =
                SinkIntent
                  { agent = agentName',
                    principalId = resolvedPrincipalId,
                    runId = runIdText,
                    ordinal,
                    occurredAt = occurredAt',
                    danwaTarget = danwaTarget',
                    resolvedRecipient = resolvedRecipient',
                    sink,
                    output
                  }
              event = sinkIntentEvent messageId runIdText now intent
              receipt = pendingDeliveryReceipt messageId kind now intent
           in PreparedSinkIntent
                { sinkResult = enqueuedResult,
                  outboxMessage = Just (OutboxMessage outboxId event),
                  deliveryReceipt = Just receipt
                }

preparedSinkResult :: PreparedSinkIntent -> SinkResult
preparedSinkResult PreparedSinkIntent {sinkResult} = sinkResult

enqueuePreparedSinkIntentTx :: PreparedSinkIntent -> Tx.Transaction ()
enqueuePreparedSinkIntentTx PreparedSinkIntent {outboxMessage, deliveryReceipt} = do
  traverse_ enqueueOutboxTx outboxMessage
  traverse_ Delivery.recordDeliveryTx deliveryReceipt

deliveryReceiptFor :: Text -> SinkKind -> Delivery.DeliveryStatus -> Maybe Text -> UTCTime -> SinkIntent -> Delivery.DeliveryReceipt
deliveryReceiptFor messageId kind = deliveryReceiptForKey (Delivery.deliveryReceiptKey messageId) messageId kind

deliveryReceiptForKey :: Text -> Text -> SinkKind -> Delivery.DeliveryStatus -> Maybe Text -> UTCTime -> SinkIntent -> Delivery.DeliveryReceipt
deliveryReceiptForKey key messageId kind receiptStatus receiptDetail now SinkIntent {agent, runId, ordinal} =
  Delivery.DeliveryReceipt
    { Delivery.receiptKey = key,
      Delivery.outboxMessageId = messageId,
      Delivery.runId = runId,
      Delivery.agent = agent,
      Delivery.ordinal = ordinal,
      Delivery.sinkKind = sinkKindText kind,
      Delivery.status = receiptStatus,
      Delivery.detail = receiptDetail,
      Delivery.updatedAt = now
    }

pendingDeliveryReceipt :: Text -> SinkKind -> UTCTime -> SinkIntent -> Delivery.DeliveryReceipt
pendingDeliveryReceipt messageId kind = deliveryReceiptFor messageId kind Delivery.Pending Nothing

sinkIntentEvent :: Text -> Text -> UTCTime -> SinkIntent -> IntegrationEvent
sinkIntentEvent messageId orderingKey occurredAt intent =
  encodeJsonIntegrationEvent
    IntegrationEvent
      { messageId,
        source = "shinzui/shikigami",
        destination = "shikigami.sink.v1",
        key = Just orderingKey,
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
      nameBytes ("shikigami:sink:" <> messageId)

publishSinkIntent :: (IOE :> es) => AgentRunDeps -> OutboxRow -> Eff es PublishOutcome
publishSinkIntent AgentRunDeps {kizashi = depsKizashi, kawa = depsKawa, danwa = depsDanwa, rei = depsRei, logger = intentLogger, grants = intentGrants, directory = intentDirectory, deliveryPool} row =
  let OutboxRow {event = integrationEvent} = row
   in case decodeJsonIntegrationEvent integrationEvent of
        Left err -> pure (PublishFailed (Text.pack (show err)))
        Right intent@SinkIntent {agent, principalId, runId, ordinal, occurredAt, danwaTarget, resolvedRecipient, sink, output} -> liftIO do
          let messageId = Integration.messageId integrationEvent
              kind = sinkKindOf sink
              sinkContext =
                SinkContext
                  { identity = AgentIdentity agent,
                    principalId,
                    directory = intentDirectory,
                    runId = runId,
                    ordinal = ordinal,
                    kizashi = depsKizashi,
                    kawa = depsKawa,
                    danwa = depsDanwa,
                    rei = depsRei,
                    danwaTarget = danwaTarget,
                    recipientOverride = resolvedRecipient,
                    occurredAt = occurredAt,
                    receipts = (\pool -> deliveryGuard pool messageId kind intent) <$> deliveryPool,
                    grants = intentGrants,
                    logger = intentLogger
                  }
              send = dispatch sinkContext sink output
          case deliveryPool of
            Nothing -> publishUntracked <$> send
            Just pool -> publishTracked intentLogger pool messageId kind intent send

publishUntracked :: SinkResult -> PublishOutcome
publishUntracked result = case outcome result of
  Failed err -> PublishFailed err
  PermanentFailure err -> either PublishFailed id (permanentPublishOutcome err)
  Enqueued detail -> PublishFailed ("dispatcher returned enqueue-only outcome during publish: " <> detail)
  _ -> PublishSucceeded

-- | Build the terminal Keiro verdict for a transport-classified permanent
-- failure. Keiro keeps rejection values abstract so every caller passes the
-- bounded audit contract through its smart constructor.
permanentPublishOutcome :: Text -> Either Text PublishOutcome
permanentPublishOutcome detail =
  first
    (("invalid terminal sink rejection: " <>) . Text.pack . show)
    (PublishRejected <$> mkPublishRejection "sink.permanent-failure" (Just detail))

publishTracked :: Log.Logger -> Pool -> Text -> SinkKind -> SinkIntent -> IO SinkResult -> IO PublishOutcome
publishTracked logger pool messageId kind intent send = do
  existing <- Delivery.lookupDelivery pool (Delivery.deliveryReceiptKey messageId)
  case existing of
    Left err -> do
      logReceiptError logger "sink.delivery.lookup_failed" messageId kind err
      pure (PublishFailed ("delivery receipt lookup failed: " <> err))
    Right (Just Delivery.DeliveryReceipt {Delivery.status = Delivery.Delivered}) -> do
      Log.logInfo
        logger
        "sink.delivery.skipped"
        [ "outbox_message_id" Aeson..= messageId,
          "sink_kind" Aeson..= sinkKindText kind,
          "reason" Aeson..= ("proven-delivered" :: Text)
        ]
      pure PublishSucceeded
    Right _ -> do
      attempting <- recordReceipt Delivery.Attempting Nothing
      case attempting of
        Left err -> do
          logReceiptError logger "sink.delivery.attempt_refused" messageId kind err
          pure (PublishFailed ("delivery receipt attempt write failed: " <> err))
        Right () -> do
          result <- send
          finish result
  where
    recordReceipt receiptStatus receiptDetail = do
      now <- getCurrentTime
      Delivery.recordDelivery pool (deliveryReceiptFor messageId kind receiptStatus receiptDetail now intent)

    finish result = case outcome result of
      Delivered downstreamId -> do
        recordReceipt Delivery.Delivered (Just downstreamId) >>= \case
          Right () -> pure PublishSucceeded
          Left err -> do
            unknownResult <- recordReceipt Delivery.Unknown (Just ("downstream acknowledged, receipt commit failed: " <> err))
            Log.logError
              logger
              "sink.delivery.unknown"
              [ "outbox_message_id" Aeson..= messageId,
                "sink_kind" Aeson..= sinkKindText kind,
                "downstream_id" Aeson..= downstreamId,
                "receipt_error" Aeson..= err,
                "unknown_write" Aeson..= either id (const ("recorded" :: Text)) unknownResult
              ]
            -- A retry here would knowingly repeat an acknowledged downstream
            -- effect. Keiro may publish the outbox row; the critical unknown
            -- event is the operator-visible repair target.
            pure PublishSucceeded
      Failed err -> recordRetryableFailure err
      PermanentFailure err ->
        case permanentPublishOutcome err of
          Left rejectionError -> recordRetryableFailure (rejectionError <> "; sink failure: " <> err)
          Right rejected -> do
            recorded <- recordReceipt Delivery.Dead (Just err)
            case recorded of
              Left receiptError -> do
                logReceiptError logger "sink.delivery.dead_write_failed" messageId kind receiptError
                pure (PublishFailed ("terminal delivery receipt write failed: " <> receiptError))
              Right () -> pure rejected
      Enqueued detail -> recordRetryableFailure ("dispatcher returned enqueue-only outcome during publish: " <> detail)
      DeniedOutcome reason -> recordTerminalNonSend ("permission denied at publish: " <> reason)
      SkippedLifecycle reason -> recordTerminalNonSend ("lifecycle skipped at publish: " <> reason)
      Stubbed -> recordTerminalNonSend "deprecated stubbed sink outcome"

    recordRetryableFailure err = do
      recordReceipt Delivery.Failed (Just err) >>= reportReceiptWrite "sink.delivery.failed_write_failed"
      pure (PublishFailed err)

    recordTerminalNonSend reason = do
      recorded <- recordReceipt Delivery.Dead (Just reason)
      case recorded of
        Left err -> do
          logReceiptError logger "sink.delivery.terminal_write_failed" messageId kind err
          pure (PublishFailed ("terminal non-send receipt write failed: " <> err))
        Right () -> pure PublishSucceeded

    reportReceiptWrite eventName = \case
      Right () -> pure ()
      Left err -> logReceiptError logger eventName messageId kind err

logReceiptError :: Log.Logger -> Text -> Text -> SinkKind -> Text -> IO ()
logReceiptError logger eventName messageId kind err =
  Log.logError
    logger
    eventName
    [ "outbox_message_id" Aeson..= messageId,
      "sink_kind" Aeson..= sinkKindText kind,
      "error" Aeson..= err
    ]

deliveryGuard :: Pool -> Text -> SinkKind -> SinkIntent -> DeliveryGuard
deliveryGuard pool messageId kind intent =
  DeliveryGuard
    { lookupReceipt = \substep -> do
        lookedUp <- Delivery.lookupDelivery pool (Delivery.subReceiptKey messageId substep)
        case lookedUp of
          Left err -> receiptIoError "lookup" err
          Right (Just Delivery.DeliveryReceipt {Delivery.status = Delivery.ConversationStarted, Delivery.detail = Just recorded}) -> pure (Just recorded)
          Right _ -> pure Nothing,
      recordReceipt = \substep recorded -> do
        now <- getCurrentTime
        let receipt =
              deliveryReceiptForKey
                (Delivery.subReceiptKey messageId substep)
                messageId
                kind
                Delivery.ConversationStarted
                (Just recorded)
                now
                intent
        Delivery.recordDelivery pool receipt >>= \case
          Left err -> receiptIoError "write" err
          Right () -> pure ()
    }
  where
    receiptIoError operation err =
      ioError (userError (Text.unpack ("delivery sub-receipt " <> operation <> " failed: " <> err)))

-- | Repair the receipt side after Keiro has durably accepted a successful
-- publication outcome. Ordinarily 'publishTracked' already wrote 'Delivered' or
-- 'Dead'. The only expected gap is a downstream acknowledgement followed by a
-- database failure; this second pass materializes the uncertainty once the
-- outbox transaction proves the row itself reached a terminal state.
reconcilePublishedSinkIntent :: AgentRunDeps -> OutboxRow -> IO ()
reconcilePublishedSinkIntent AgentRunDeps {deliveryPool = Nothing} _ = pure ()
reconcilePublishedSinkIntent AgentRunDeps {deliveryPool = Just pool, logger} row = do
  let OutboxRow {event = integrationEvent} = row
      messageId = Integration.messageId integrationEvent
  case decodeJsonIntegrationEvent integrationEvent of
    Left err ->
      Log.logError
        logger
        "sink.delivery.reconciliation_decode_failed"
        [ "outbox_message_id" Aeson..= messageId,
          "error" Aeson..= Text.pack (show err)
        ]
    Right intent@SinkIntent {sink} -> do
      let kind = sinkKindOf sink
      Delivery.lookupDelivery pool (Delivery.deliveryReceiptKey messageId) >>= \case
        Left err -> logReceiptError logger "sink.delivery.reconciliation_lookup_failed" messageId kind err
        Right (Just Delivery.DeliveryReceipt {Delivery.status = receiptStatus})
          | receiptStatus `elem` [Delivery.Delivered, Delivery.Dead, Delivery.Unknown] -> pure ()
        Right _ -> do
          now <- getCurrentTime
          let detail = Just "outbox published without a terminal delivery receipt"
          Delivery.recordDelivery pool (deliveryReceiptFor messageId kind Delivery.Unknown detail now intent) >>= \case
            Left err -> logReceiptError logger "sink.delivery.reconciliation_write_failed" messageId kind err
            Right () ->
              Log.logError
                logger
                "sink.delivery.reconciled_unknown"
                [ "outbox_message_id" Aeson..= messageId,
                  "sink_kind" Aeson..= sinkKindText kind
                ]

-- | Record the run's learning, if the declared policy asks for one.
--
-- A declaration that says @recordPolicy = Always@ and a run that reports success
-- having persisted nothing disagree about what the agent did. The store result
-- is therefore returned, not discarded; 'requireStore' at the call site fails the
-- run instead.
recordLearning :: (IOE :> es) => AgentRunDeps -> AgentDecl -> SessionId -> Value -> Eff es (Either StoreError (StepResult (Maybe MemoryId)))
recordLearning deps decl@AgentDecl {memory = MemoryPolicy {recordPolicy}} sid output = liftIO do
  case recordPolicy of
    Never -> pure (Right (StepProduced Nothing))
    OnSuccess -> recordedJust
    Always -> recordedJust
  where
    recordedJust = (fmap . fmap) (fmap Just) recordSuccess

    recordSuccess =
      recordMemory
        deps
        decl
        sid
        (renderLearning output)
        (Set.fromList ["agent-run", behaviorKindText (behavior decl)])

recordMemory :: AgentRunDeps -> AgentDecl -> SessionId -> Text -> Set.Set Text -> IO (Either StoreError (StepResult MemoryId))
recordMemory deps decl sid content' tags' = do
  mid <- genMemoryId
  recordedAt' <- getCurrentTime
  kiokuWrite "recording the run's learning" $
    Memory.record
      RecordMemoryData
        { memoryId = mid,
          memorySpaceId = shikigamiMemorySpace,
          actorPrincipal = agentActor (agentDeclName decl),
          ownerPrincipal = Nothing,
          agentId = agentDeclName decl,
          sessionId = Just sid,
          scope = agentScope (agentDeclName decl),
          memoryType = MemoryPattern,
          content = content',
          priority = 100,
          confidence = MediumConfidence,
          tags = tags',
          supersedes = Nothing,
          recordedAt = recordedAt'
        }
      & runKioku deps

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
completeSession :: (IOE :> es) => AgentRunDeps -> BehaviorEnv -> AgentDecl -> SessionId -> Eff es (Either StoreError (StepResult ()))
completeSession deps activeBehaviorEnv decl sid = liftIO do
  completedAt' <- getCurrentTime
  kiokuWrite "completing the run's kioku session" $
    (fmap . fmap) void $
      Session.complete
        CompleteSessionData
          { sessionId = sid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor (agentDeclName decl),
            completedAt = completedAt',
            modelUsed = Just (behaviorModelId activeBehaviorEnv),
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
      PermanentFailure _ -> Log.Error
      DeniedOutcome _ -> Log.Warn
      SkippedLifecycle _ -> Log.Warn
      _ -> Log.Info
    outcomeText :: SinkOutcome -> Text
    outcomeText = \case
      Delivered _ -> "delivered"
      Enqueued _ -> "enqueued"
      Stubbed -> "stubbed"
      DeniedOutcome _ -> "denied"
      SkippedLifecycle _ -> "skipped_lifecycle"
      Failed _ -> "failed"
      PermanentFailure _ -> "permanent_failure"
    -- The detail rides under a key that says what kind of detail it is, so that
    -- a query for failures can read @error@ without also matching the returned
    -- id of a successful delivery.
    detailField = \case
      Delivered detail -> ["detail" Aeson..= detail]
      Enqueued detail -> ["detail" Aeson..= detail]
      Stubbed -> []
      DeniedOutcome reason -> ["reason" Aeson..= reason]
      SkippedLifecycle reason -> ["reason" Aeson..= reason]
      Failed err -> ["error" Aeson..= err]
      PermanentFailure err -> ["error" Aeson..= err]

triggerKindText :: Trigger -> Text
triggerKindText = \case
  Schedule {} -> "schedule"
  Stream {} -> "stream"
  Event {} -> "event"

spanArgs :: SpanKind -> SpanArguments
spanArgs spanKind =
  Otel.defaultSpanArguments {Otel.kind = spanKind}
