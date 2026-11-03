{-# LANGUAGE DataKinds #-}
{-# OPTIONS_GHC -O0 #-}

-- GHC 9.12.4 at -O1 crashes in GC after the expanded Flow interpreter suspends,
-- including a fresh build. Keep this boundary unoptimized until a compiler
-- upgrade passes the forced-GC replay regression (FRIC-13). Model/tool execution
-- and the remaining modules retain their ordinary optimization settings.

module Shikigami.Agent.Workflow
  ( AgentRunDeps (..),
    executionRuntime,
    executeAcceptedOperation,
    workerSessionRuntime,
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
    resolveCapabilitiesForRun,
    runBehaviorWithCapabilities,
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

import Control.Exception (fromException, throwIO)
import Data.Aeson (Key, Value, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, throwError_)
import Effectful.Exception (trySync)
import Effectful.Exception qualified as EffException
import Hasql.Pool (Pool)
import Keiro.Integration.Event qualified as Integration
import Keiro.Outbox (OutboxRow (..), PublishOutcome (..), mkPublishRejection)
import Keiro.Telemetry (traceContextFromCurrentSpan)
import Keiro.Workflow
  ( StepName (..),
    Workflow,
    WorkflowId (..),
    WorkflowOutcome,
    currentWorkflow,
    runWorkflowWith,
    step,
  )
import Keiro.Workflow qualified as Workflow
import Keiro.Workflow.Child (WorkflowChildFailed (..))
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Kioku.Api.Types (Confidence (MediumConfidence), MemoryRecord, MemoryType (MemoryPattern))
import Kioku.Id (MemoryId, SessionId, genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Session qualified as Session
import Kioku.Session.Domain (CompleteSessionData (..), FailSessionData (..), StartSessionData (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import OpenTelemetry.Trace.Core qualified as Otel
import Shibuya.Telemetry.Effect (SpanArguments, SpanKind (..), Tracing, addAttribute, withSpan')
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.Activity qualified as Activity
import Shikigami.Agent.Approval
  ( ApprovalDecision (..),
    ApprovalPolicySnapshot,
    ApprovalRequest (..),
    approvalPolicyChannel,
    approvalPolicyDeadline,
    requiresApprovalFor,
  )
import Shikigami.Agent.Approval.Workflow qualified as ApprovalWorkflow
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), DelegationBudget, IdentityDecl (..), MemoryPolicy (..), ProfileRequirement (..), RecordPolicy (..), Sink, Trigger (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Delegate (awaitAllDelegated, delegate)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Delegate.Depth (depthInt, initialDepth)
import Shikigami.Agent.Name (agentNameText, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (UnresolvedLegacyIdentity), ResolvedAgentIdentity, identityText, resolveAgentIdentity, resolvedIdentityText)
import Shikigami.Agent.Run (AgentRunResult (..), behaviorKindText, recallAgentLearnings, recallQuery, renderLearning)
import Shikigami.Agent.Run.Key (runKeyText)
import Shikigami.Agent.RunFailure (AgentRunFailure (..), agentRunFailureDetail)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName, ingestJobStepName)
import Shikigami.App (AppEffects, AppEnv (..), runAppIO)
import Shikigami.Attestation.PolicyValue qualified as DecisionLimits
import Shikigami.Attestation.Profile (ProfileId (..), ProfileVersion (..))
import Shikigami.Attestation.Resolve (ProfileResolutionError, ResolvedProfile, ResolvedProfileView (..), renderProfileResolutionError, resolvedProfileView)
import Shikigami.Behavior.Error (RunError, TransientBehaviorFailure (..), boundedBehaviorDetail)
import Shikigami.Behavior.Provider (ProfileViolation, constrainBehaviorEnv, renderProfileViolation)
import Shikigami.Behavior.Provider.Coordinate (providerCoordinateText)
import Shikigami.Behavior.Run (BehaviorEnv (..), BehaviorInput (..), behaviorModelId, runBehavior, runBehaviorAttemptWith, withCapabilityTools)
import Shikigami.Behavior.Skill (SkillDir (..))
import Shikigami.Capability.Catalog qualified as Capability
import Shikigami.Capability.Overlay (CapabilityDescriptor, ResolvedCapabilitySet, capabilityIdText)
import Shikigami.Capability.Provider
  ( CapabilityRun (..),
    CapabilityRuntime (..),
    CapabilityRuntimeError,
    CapabilityScope (..),
    durableAdapterInstalled,
    withCapabilityOverlays,
  )
import Shikigami.Decision.Contract (renderDecisionFailure)
import Shikigami.Decision.Contract qualified as DecisionContract
import Shikigami.Decision.Evidence qualified as DecisionEvidence
import Shikigami.Decision.Execution qualified as DecisionExecution
import Shikigami.Decision.ModelCatalog qualified as ModelCatalog
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Directory qualified as Directory
import Shikigami.Duration
import Shikigami.Execution.Attempt qualified as ExecutionAttempt
import Shikigami.Execution.Driver qualified as ExecutionDriver
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Policy.Types qualified as Harness
import Shikigami.Execution.Request (ExecutionPolicy (..), ExecutionRequest (..))
import Shikigami.Execution.Resources (ResourceError)
import Shikigami.Execution.ResourcesStore qualified as ExecutionResources
import Shikigami.Execution.Selection qualified as Selection
import Shikigami.Execution.SelectionRuntime qualified as SelectionRuntime
import Shikigami.Execution.Start qualified as ExecutionStart
import Shikigami.Execution.Tools qualified as ExecutionTools
import Shikigami.Execution.Transcript qualified as Execution
import Shikigami.Flow qualified as Flow
import Shikigami.Flow.Acknowledgement
  ( ApprovalAcknowledgementFailed (..),
    runAcknowledgementWithChild,
  )
import Shikigami.Flow.Capability qualified as FlowCapability
import Shikigami.Flow.Decision qualified as FlowDecision
import Shikigami.Flow.Delegate qualified as FlowDelegate
import Shikigami.Flow.Objectives qualified as FlowObjectives
import Shikigami.Flow.Routing (RoutingRuntime)
import Shikigami.Flow.Routing qualified as FlowRouting
import Shikigami.Flow.Workers qualified as FlowWorkers
import Shikigami.Log qualified as Log
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace, shikigamiWriteContext)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Objective.Runtime qualified as Objectives
import Shikigami.Objective.Store qualified as ObjectiveStore
import Shikigami.Objective.Tools qualified as ObjectiveTools
import Shikigami.Objective.Types qualified as Objective
import Shikigami.PracticeReview.Attention qualified as PracticeReviewAttention
import Shikigami.PracticeReview.Capability qualified as PracticeReview
import Shikigami.PracticeReview.Memory qualified as PracticeReviewMemory
import Shikigami.Prelude hiding ((.=))
import Shikigami.Program.DecisionRunner (DecisionAbort (..))
import Shikigami.Program.DecisionRunner qualified as DecisionRunner
import Shikigami.RuntimePolicy (defaultModelRequired)
import Shikigami.Sink (DanwaConfig, DeliveryGuard (..), GrantSource, KanmonConfig, KawaConfig, KizashiConfig, ReiConfig, SinkContext (..), SinkOutcome (..), SinkResult (..), dispatch, sinkKindOf)
import Shikigami.Sink.Delivery qualified as Delivery
import Shikigami.Sink.GrantStore (withActionAuthorizer)
import Shikigami.Sink.Http (SinkHttp)
import Shikigami.Sink.Intent
  ( PreparedSinkIntent,
    SinkIntent (..),
    decodeSinkIntentEvent,
    deliveryContextFor,
    deliveryReceiptFor,
    deliveryReceiptForKey,
    enqueuePreparedSinkIntentTx,
    enqueueSinkIntentStep,
    enqueueSinkIntents,
    prepareSinkIntent,
    preparedSinkResult,
  )
import Shikigami.Sink.Permission (SinkKind, sinkKindText)
import Shikigami.Telemetry.TraceContext qualified as TraceContext
import Shikigami.WorkerSession.Capability qualified as WorkerCapability
import Shikigami.WorkerSession.Handoff qualified as WorkerHandoff
import Shikigami.WorkerSession.Tools qualified as WorkerTools
import Shikigami.WorkerSession.Workflow qualified as WorkerSession
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import Shikigami.Workspace.Admission (WorkspaceHost (..))

data AgentRunDeps = AgentRunDeps
  { appEnv :: !AppEnv,
    behaviorEnv :: !BehaviorEnv,
    decisions :: !FlowDecision.DecisionServices,
    -- | Process-local C13 authorizer. The value never crosses a workflow or
    -- outbox boundary; every protected IO boundary asks it afresh.
    actionAuthorizer :: !ActionAuthorizer,
    -- | Operator-owned overlay catalog, policy, and exact-revision provider
    -- factories. Only its pure resolution result crosses the journal boundary.
    capabilities :: !CapabilityRuntime,
    workspace :: !(Maybe WorkspaceHost),
    -- | No production scope/provider is selected until IR-11/IR-13 deliver it.
    coordination :: !(Maybe WorkerCapability.CoordinationHost),
    objectives :: !(Maybe Objectives.ObjectiveRuntime),
    agents :: ![AgentDecl],
    kizashi :: !KizashiConfig,
    kawa :: !KawaConfig,
    kanmon :: !KanmonConfig,
    danwa :: !DanwaConfig,
    rei :: !ReiConfig,
    -- | Process-lifetime sink clients. This dependency never crosses a journal
    -- or outbox serialization boundary.
    http :: !SinkHttp,
    hooks :: !AgentRunHooks,
    -- | Mutable process policy, snapshotted once in each new run.
    approvalPolicy :: !ApprovalPolicySnapshot,
    -- | Process resources for the approval child registered alongside this
    -- agent-run workflow. The value itself never crosses a journal boundary.
    approvalWorkflow :: !ApprovalWorkflow.ApprovalWorkflowEnv,
    runTimeout :: !(Duration "agent-run"),
    harness :: !Harness.HarnessPolicy,
    -- | Root-run descendant limit used when an agent declaration leaves its
    -- own delegation budget absent.
    delegationBudget :: !DelegationBudget,
    -- | Which grant source the enqueue-time C11 check consults, and the one
    -- handed to every 'SinkContext' this run builds.
    grants :: !GrantSource,
    -- | Cached principal lifecycle and attribution view shared with trigger and
    -- drain gates.
    directory :: !DirectoryHandle,
    -- | Process-local catalog/evaluator seam. Catalog and raw decision values
    -- cross the workflow journal before they can influence delegation.
    routing :: !RoutingRuntime,
    -- | Process-local content, evaluation, and attention adapters for the
    -- specialist review Flow. Their outputs cross fixed journal steps before
    -- they can influence the Flow body.
    practiceReview :: !PracticeReview.PracticeReviewRuntime,
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
  deriving stock (Generic)

data AgentRunHooks = AgentRunHooks
  { beforeStepBody :: !(StepName -> IO ()),
    afterStepBody :: !(StepName -> IO ())
  }
  deriving stock (Generic)

defaultAgentRunHooks :: AgentRunHooks
defaultAgentRunHooks =
  AgentRunHooks
    { beforeStepBody = \_ -> pure (),
      afterStepBody = \_ -> pure ()
    }

agentDeclName :: AgentDecl -> Text
agentDeclName AgentDecl {name} = agentNameText name

jobIdempotencyKey :: RunJob -> Text
jobIdempotencyKey RunJob {idempotencyKey} = runKeyText idempotencyKey

-- | Named rather than used as a bare selector because 'SinkContext' also has a
-- @logger@ field, and @DuplicateRecordFields@ makes the unqualified use
-- ambiguous wherever both records are in scope.
depsLogger :: AgentRunDeps -> Log.Logger
depsLogger AgentRunDeps {logger = l} = l

-- | Named for the same reason as 'depsLogger': 'SinkContext' and
-- 'FlowCapability.SinkEnv' also carry a @grants@ field.
depsGrants :: AgentRunDeps -> GrantSource
depsGrants AgentRunDeps {grants = g, actionAuthorizer} = withActionAuthorizer actionAuthorizer g

depsDirectory :: AgentRunDeps -> DirectoryHandle
depsDirectory AgentRunDeps {directory = value} = value

depsRouting :: AgentRunDeps -> RoutingRuntime
depsRouting AgentRunDeps {routing = value} = value

depsRunTimeout :: AgentRunDeps -> Duration "agent-run"
depsRunTimeout AgentRunDeps {runTimeout = timeout} = timeout

depsDelegationBudget :: AgentRunDeps -> DelegationBudget
depsDelegationBudget AgentRunDeps {delegationBudget = value} = value

depsApprovalPolicy :: AgentRunDeps -> ApprovalPolicySnapshot
depsApprovalPolicy AgentRunDeps {approvalPolicy = value} = value

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
  admission <- runStep deps (StepName "validate-execution-root") (validateExecutionRoot job)
  case admission of
    Left refusal -> pure (Left (PermanentAgentRunFailure (Text.pack (show refusal))))
    Right () -> runAdmittedAgent deps job

validateExecutionRoot :: (Store :> es) => RunJob -> Eff es (Either ResourceError ())
validateExecutionRoot job = case job.executionRootId of
  Nothing -> pure (Right ())
  Just root -> fmap (fmap (const ())) (ExecutionResources.inspectRoot root)

runAdmittedAgent :: AgentRunDeps -> RunJob -> Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult)
runAdmittedAgent deps job = do
  mDecl <- runStep deps (StepName "lookup-agent") (pure (find ((== (agentNameText ((.agentName) job))) . agentDeclName) ((.agents) deps)))
  case mDecl of
    Nothing -> pure (Left (PermanentAgentRunFailure ("unknown agent " <> (agentNameText ((.agentName) job)))))
    Just decl -> runResolvedAgent deps job decl

runAgentRunWorkflow ::
  AgentRunDeps ->
  RunJob ->
  IO (Either StoreError (WorkflowOutcome (Either AgentRunFailure AgentRunResult)))
runAgentRunWorkflow deps job =
  let env = (.appEnv) deps
   in runAppIO env $
        runWorkflowWith
          (shikigamiWorkflowRunOptions env)
          agentRunWorkflowName
          (runJobWorkflowId job)
          (agentRunWorkflow deps (Just job))

agentRunRegistry :: AgentRunDeps -> WorkflowRegistry AppEffects
agentRunRegistry deps =
  Map.singleton agentRunWorkflowName (WorkflowDef \_wid -> agentRunWorkflow deps Nothing)
    `Map.union` ApprovalWorkflow.approvalRegistry ((.approvalWorkflow) deps)

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
  profileResolution <- runStep deps (StepName "resolve-profile") (liftIO (resolveRequiredProfile deps decl))
  case profileResolution of
    Left refusal -> pure (Left (PermanentAgentRunFailure (renderProfileResolutionError refusal)))
    Right resolvedProfile -> do
      capabilityResolution <-
        runStep
          deps
          (StepName (if requestsWorkspace decl then "resolve-governed-capability-overlays" else "resolve-capability-overlays"))
          (pure (if requestsWorkspace decl then resolveGovernedCapabilitiesForRun deps.capabilities decl resolvedProfile else resolveCapabilitiesForRun deps.capabilities decl resolvedProfile))
      case capabilityResolution of
        Left refusal ->
          pure
            ( Left
                ( PermanentAgentRunFailure
                    (boundedBehaviorDetail (Text.pack (show refusal)))
                )
            )
        Right resolvedOverlays ->
          runProfiledAgent deps job decl resolvedProfile resolvedOverlays

-- | Resolve an agent-authored request through one operator runtime snapshot.
-- The already journaled profile is part of the authorization subject; policy
-- never re-reads mutable profile state independently of the workflow.
resolveCapabilitiesForRun ::
  CapabilityRuntime ->
  AgentDecl ->
  Maybe ResolvedProfile ->
  Either Capability.CapabilityResolutionError ResolvedCapabilitySet
resolveCapabilitiesForRun = resolveRunCapabilities (const False)

resolveGovernedCapabilitiesForRun :: CapabilityRuntime -> AgentDecl -> Maybe ResolvedProfile -> Either Capability.CapabilityResolutionError ResolvedCapabilitySet
resolveGovernedCapabilitiesForRun runtime = resolveRunCapabilities (durableAdapterInstalled runtime.providers) runtime

requestsWorkspace :: AgentDecl -> Bool
requestsWorkspace decl = any ((`elem` ["workspace.edit", "workspace.exec", "workspace.git"]) . capabilityIdText) decl.capabilityOverlays

resolveRunCapabilities :: (CapabilityDescriptor -> Bool) -> CapabilityRuntime -> AgentDecl -> Maybe ResolvedProfile -> Either Capability.CapabilityResolutionError ResolvedCapabilitySet
resolveRunCapabilities installed CapabilityRuntime {catalog, authorize} AgentDecl {behavior, capabilityOverlays, delegates, identity} resolvedProfile
  | not (null capabilityOverlays) && not (null delegates) =
      Left Capability.CapabilityBehaviorUnsupported {Capability.behaviorKind = "DelegatingSkill"}
  | otherwise =
      Capability.resolveGovernedCapabilityOverlays
        installed
        catalog
        authorize
        Capability.ResolutionSubject
          { Capability.principal = declared <$> identity,
            Capability.mode = Capability.Durable,
            Capability.behavior = behavior,
            Capability.profile = resolvedProfile
          }
        capabilityOverlays
  where
    declared IdentityDecl {principal} = principal

runProfiledAgent ::
  AgentRunDeps ->
  RunJob ->
  AgentDecl ->
  Maybe ResolvedProfile ->
  ResolvedCapabilitySet ->
  Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult)
runProfiledAgent deps job decl resolvedProfile resolvedOverlays = do
  selected <- runStep deps (StepName "resolve-execution-selection") do
    now <- liftIO getCurrentTime
    pure (resolveRunSelection deps job decl resolvedProfile now)
  case selected of
    Left refusal -> pure (Left (PermanentAgentRunFailure (selectionRefusalDetail deps job decl resolvedProfile Nothing refusal)))
    Right Nothing -> runWith ((.behaviorEnv) deps) (job & #executionPermissions .~ inheritedPermissions decl job)
    Right (Just selection)
      | durableSkill decl ->
          let permissions = case selection.source of
                Selection.DeclaredAlias -> Just selection.permittedAliases
                Selection.ProcessDefault -> inheritedPermissions decl job
           in runProfiledAgentWith deps deps.behaviorEnv (Just selection) resolvedProfile resolvedOverlays (job & #executionPermissions .~ permissions) decl
    Right (Just selection) -> do
      built <- liftIO (SelectionRuntime.buildExecutionEnv (selectionRuntime deps job resolvedProfile) selection)
      case built of
        Left refusal -> pure (Left (PermanentAgentRunFailure (selectionRefusalDetail deps job decl resolvedProfile (Just selection) refusal)))
        Right active ->
          let permissions = case selection.source of
                Selection.DeclaredAlias -> Just selection.permittedAliases
                Selection.ProcessDefault -> inheritedPermissions decl job
           in runWith active (job & #executionPermissions .~ permissions)
  where
    runWith active selectedJob = case behaviorEnvForProfile decl resolvedProfile active of
      Left violation -> pure (Left (PermanentAgentRunFailure (renderProfileViolation violation)))
      Right constrained -> runProfiledAgentWith deps constrained Nothing resolvedProfile resolvedOverlays selectedJob decl

durableSkill :: AgentDecl -> Bool
durableSkill decl = case decl.behavior of
  Skill {} -> null decl.delegates && isNothing decl.routing
  CoordinatingSkill {} -> isNothing decl.routing
  _ -> False

resolveRunSelection :: AgentRunDeps -> RunJob -> AgentDecl -> Maybe ResolvedProfile -> UTCTime -> Either Selection.ExecutionSelectionFailure (Maybe Selection.ExecutionSelection)
resolveRunSelection deps job decl profile now
  | usesDefaultModel decl = Just <$> Selection.resolveExecutionSelection (SelectionRuntime.assignmentIdFor ((runJobWorkflowId job).unWorkflowId)) deps.decisions.catalog (Selection.defaultBinding deps.behaviorEnv.model deps.behaviorEnv.options) decl.execution job.executionRequest job.executionPermissions profile job.executionRootId now
  | isJust job.executionRequest = Left Selection.ExecutionBehaviorUnsupported
  | otherwise = Right Nothing

usesDefaultModel :: AgentDecl -> Bool
usesDefaultModel decl = case decl.behavior of
  Skill {} -> null decl.delegates || isJust decl.routing
  CoordinatingSkill {} -> True
  Flow {name} -> maybe True (defaultModelRequired . (.requiresDefaultModel)) (Flow.lookupFlow name)
  _ -> isJust decl.routing

inheritedPermissions :: AgentDecl -> RunJob -> Maybe [DecisionContract.ModelAlias]
inheritedPermissions decl job =
  foldr
    intersect
    Nothing
    [ job.executionPermissions,
      job.executionRequest >>= (.permittedAliases),
      (.permittedAliases) <$> decl.execution
    ]
  where
    intersect Nothing current = current
    intersect (Just allowed) Nothing = Just allowed
    intersect (Just allowed) (Just current) = Just (filter (`elem` allowed) current)

selectionRefusalDetail :: AgentRunDeps -> RunJob -> AgentDecl -> Maybe ResolvedProfile -> Maybe Selection.ExecutionSelection -> Selection.ExecutionSelectionFailure -> Text
selectionRefusalDetail deps job decl profile selected refusal =
  boundedBehaviorDetail
    (Text.pack (show refusal) <> " model " <> model <> maybe "" (\p -> " profile " <> Text.pack (show (resolvedProfileView p).ref)) profile)
  where
    model = case selected of
      Just pinned -> providerCoordinateText pinned.descriptor.modelId
      Nothing -> case decl.execution of
        Nothing -> behaviorModelId deps.behaviorEnv
        Just permission ->
          let alias = fromMaybe permission.defaultAlias (job.executionRequest >>= (.alias))
           in maybe (DecisionContract.modelAliasText alias) (providerCoordinateText . (.modelId)) (find (\d -> d.alias == alias) (ModelCatalog.catalogDescriptors deps.decisions.catalog))

-- The queue executor and the future driver share these process-owned
-- dependencies. No live function or credential enters an execution snapshot.
executionRuntime :: AgentRunDeps -> Executor.ExecutionRuntime
executionRuntime deps =
  Executor.ExecutionRuntime
    { appEnv = deps.appEnv,
      replayAuthority = Directory.identityLifecycleAdmission (depsDirectory deps),
      authorize = authority,
      selectionRuntime = \snapshot ->
        SelectionRuntime.SelectionRuntime
          { catalog = deps.decisions.catalog,
            profile = snapshot.sanctionedProfile,
            providers = deps.decisions.providers,
            baseEnv = deps.behaviorEnv,
            runId = runCorrelationId snapshot.runId.unWorkflowId,
            authorize = authority snapshot,
            transact = SelectionRuntime.selectionTransaction deps.appEnv deps.deliveryPool
          },
      withTools = ExecutionTools.withExecutionTools deps.logger deps.actionAuthorizer deps.capabilities.providers (executionTools deps),
      timeoutSeconds = deps.runTimeout
    }
  where
    authority (snapshot :: Execution.ExecutionSnapshot) = SelectionRuntime.currentExecutionAuthority (Directory.identityLifecycleAdmission (depsDirectory deps) snapshot.identity) snapshot.sanctionedProfile deps.resolveRunProfile

-- Typed decisions are queue work, never a long workflow step. This compatible
-- executor entry point keeps the original runtime constructor for other callers.
executeAcceptedOperation :: AgentRunDeps -> AgentIdentity -> ExecutionAttempt.JobReference -> IO (Either Execution.ExecutionError Executor.ExecutorResult)
executeAcceptedOperation deps identity reference =
  Executor.executeAcceptedAttemptWithDecision runTyped (executionRuntime deps) identity reference
  where
    runTyped snapshot work authorize = case deps.deliveryPool of
      Nothing -> pure (Left Execution.ExecutionStorageUnavailable)
      Just pool -> do
        let evidence = DecisionEvidence.postgresDecisionEvidenceStore pool
            runtime =
              DecisionRunner.DecisionRuntime
                { runtime = deps.behaviorEnv.runtime,
                  programs = deps.decisions.programs,
                  catalog = deps.decisions.catalog,
                  profile = snapshot.sanctionedProfile,
                  hooks = DecisionEvidence.decisionCallHooks evidence snapshot.sanctionedProfile,
                  providers = deps.decisions.providers,
                  timeoutMicros = either (error . show) id (DecisionContract.parseDecisionTimeout (max 1 (floor (durationTime deps.runTimeout * 1000000)))),
                  callLimit = either (error . show) id (DecisionLimits.mkCeiling 64)
                }
        DecisionExecution.executeDecisionWork evidence (const runtime) snapshot work authorize

executionTools :: AgentRunDeps -> ExecutionTools.NativeToolFactory
-- Accepted execution bindings determine which coordination scope is reacquired.
executionTools deps = WorkerTools.appendNativeFactory (WorkerTools.appendNativeFactory (ExecutionTools.staticNativeTools deps.behaviorEnv.tools) (WorkerTools.coordinationTools deps.coordination deps.actionAuthorizer)) (ObjectiveTools.objectiveTools deps.objectives)

workerSessionRuntime :: AgentRunDeps -> WorkerSession.SessionRuntime
workerSessionRuntime deps = case deps.coordination of
  Just host -> host.services.sessions
  Nothing -> WorkerSession.SessionRuntime deps.appEnv deps.agents deps.directory (Directory.identityLifecycleAdmission deps.directory) Nothing Nothing

selectionRuntime :: AgentRunDeps -> RunJob -> Maybe ResolvedProfile -> SelectionRuntime.SelectionRuntime
selectionRuntime deps job profile =
  SelectionRuntime.SelectionRuntime
    { catalog = deps.decisions.catalog,
      profile,
      providers = deps.decisions.providers,
      baseEnv = deps.behaviorEnv,
      runId = runCorrelationId (jobIdempotencyKey job),
      authorize = SelectionRuntime.currentExecutionAuthority (Directory.identityLifecycleAdmission (depsDirectory deps) job.identity) profile deps.resolveRunProfile,
      transact = SelectionRuntime.selectionTransaction deps.appEnv deps.deliveryPool
    }

behaviorEnvForProfile ::
  AgentDecl ->
  Maybe ResolvedProfile ->
  BehaviorEnv ->
  Either ProfileViolation BehaviorEnv
behaviorEnvForProfile AgentDecl {behavior = Skill {}} (Just resolvedProfile) =
  constrainBehaviorEnv resolvedProfile
behaviorEnvForProfile AgentDecl {behavior = CoordinatingSkill {}} (Just resolvedProfile) =
  constrainBehaviorEnv resolvedProfile
behaviorEnvForProfile AgentDecl {behavior = Flow {name}} (Just resolvedProfile) =
  case Flow.lookupFlow name of
    Just flow | not (defaultModelRequired flow.requiresDefaultModel) -> Right
    _ -> constrainBehaviorEnv resolvedProfile
behaviorEnvForProfile AgentDecl {routing = Just _} (Just resolvedProfile) =
  constrainBehaviorEnv resolvedProfile
behaviorEnvForProfile _decl _resolvedProfile = Right

runProfiledAgentWith ::
  AgentRunDeps ->
  BehaviorEnv ->
  Maybe Selection.ExecutionSelection ->
  Maybe ResolvedProfile ->
  ResolvedCapabilitySet ->
  RunJob ->
  AgentDecl ->
  Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult)
runProfiledAgentWith deps activeBehaviorEnv durableSelection resolvedProfile resolvedOverlays job decl =
  case resolveAgentIdentity (job ^. #identity) of
    Left problem -> pure (Left (PermanentAgentRunFailure problem))
    Right recordedIdentity -> runResolved recordedIdentity
  where
    runResolved recordedIdentity = do
      withSpan' "trigger" (spanArgs Internal) \traceSpan -> do
        addAttribute traceSpan "agent.name" ((agentNameText ((.agentName) job)))
        addAttribute traceSpan "trigger.kind" (triggerKindText ((.trigger) decl))
        addAttribute traceSpan "run.idempotency_key" (jobIdempotencyKey job)
      approvalPolicyForRun <- runStep deps (StepName "resolve-approval-policy") (pure (depsApprovalPolicy deps))
      opened <- runStep deps (StepName "open-session") (requireStore (openSession deps recordedIdentity job decl))
      case opened of
        -- kioku refused to open the session. The same command will be refused on
        -- every replay, so there is nothing to retry and the run is over.
        StepRefused detail -> pure (Left (PermanentAgentRunFailure detail))
        StepProduced sid -> runSessionedAgent deps activeBehaviorEnv durableSelection resolvedProfile resolvedOverlays approvalPolicyForRun recordedIdentity job decl sid

-- | The rest of one agent run, once its kioku session is open.
runSessionedAgent ::
  AgentRunDeps ->
  BehaviorEnv ->
  Maybe Selection.ExecutionSelection ->
  Maybe ResolvedProfile ->
  ResolvedCapabilitySet ->
  ApprovalPolicySnapshot ->
  ResolvedAgentIdentity ->
  RunJob ->
  AgentDecl ->
  SessionId ->
  Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult)
runSessionedAgent deps activeBehaviorEnv durableSelection resolvedProfile resolvedOverlays approvalPolicyForRun recordedIdentity job decl@AgentDecl {memory = MemoryPolicy {recallLimit = declaredRecallLimit}} sid = do
  prior <- runStep deps (StepName "recall") (liftIO (recallAgentLearnings ((.appEnv) deps) ((.deliveryPool) deps) declaredRecallLimit recordedIdentity (recallQuery decl (behaviorKindText ((.behavior) decl)) ((.triggerPayload) job))))
  behaviorE <-
    withSpan' "behavior" (spanArgs Internal) \traceSpan -> do
      addAttribute traceSpan "agent.name" (agentDeclName decl)
      addAttribute traceSpan "behavior.kind" (behaviorKindText ((.behavior) decl))
      useObjectives <- Workflow.patch (Workflow.PatchId "shikigami-objective-tracking-v1")
      let requested = isJust job.objective || maybe False (\host -> ObjectiveStore.creationAllowed host.settings (Objective.RecordedAgent job.identity)) deps.objectives
          supported = case decl.behavior of Flow {} -> True; Skill {} -> isJust durableSelection; CoordinatingSkill {} -> isJust durableSelection; _ -> False
      if useObjectives && requested && not supported
        then pure (Left (PermanentAgentRunFailure "objective work requires durable Skill or Flow execution"))
        else do
          case (.behavior) decl of
            CoordinatingSkill {path}
              | Just selection <- durableSelection ->
                  first PermanentAgentRunFailure <$> runDurableSkillStep deps resolvedProfile resolvedOverlays job decl sid prior selection path
              | otherwise -> pure (Left (PermanentAgentRunFailure "coordinating Skills require compatible durable execution and no routing policy"))
            Skill {path}
              | Just selection <- durableSelection ->
                  first PermanentAgentRunFailure <$> runDurableSkillStep deps resolvedProfile resolvedOverlays job decl sid prior selection path
            Flow {} -> first PermanentAgentRunFailure <$> runBehaviorStep deps activeBehaviorEnv resolvedProfile approvalPolicyForRun recordedIdentity sid decl job prior
            _
              | not (null ((.delegates) decl)) ->
                  first PermanentAgentRunFailure <$> runBehaviorStep deps activeBehaviorEnv resolvedProfile approvalPolicyForRun recordedIdentity sid decl job prior
              | otherwise ->
                  first PermanentAgentRunFailure
                    <$> runStep
                      deps
                      (StepName "run-behavior-v2")
                      ( liftIO
                          ( runBehaviorAttemptWith
                              (durationTime (depsRunTimeout deps))
                              do
                                acquired <-
                                  runBehaviorWithCapabilities
                                    (depsLogger deps)
                                    ((.actionAuthorizer) deps)
                                    ((.capabilities) deps)
                                    (capabilityScopeForRun job)
                                    resolvedOverlays
                                    activeBehaviorEnv
                                    decl
                                    BehaviorInput {payload = (.triggerPayload) job, recalled = prior}
                                case acquired of
                                  Left runtimeError ->
                                    throwIO
                                      ( TransientBehaviorFailure
                                          (boundedBehaviorDetail (Text.pack (show runtimeError)))
                                      )
                                  Right behaviorResult -> pure behaviorResult
                          )
                      )
  case behaviorE of
    Left err -> finishRunFailure deps recordedIdentity decl sid err
    Right output -> finishSuccessfulRun deps (maybe (behaviorModelId activeBehaviorEnv) (\selection -> providerCoordinateText selection.descriptor.modelId) durableSelection) approvalPolicyForRun recordedIdentity job decl sid prior output

-- The new branch journals admission metadata and awaits a registered child.
-- The terminal body is a protected read; memory and sinks retain their existing
-- owners and step labels below.
runDurableSkillStep :: AgentRunDeps -> Maybe ResolvedProfile -> ResolvedCapabilitySet -> RunJob -> AgentDecl -> SessionId -> [MemoryRecord] -> Selection.ExecutionSelection -> DeclarationCoordinate "skill-path" -> Eff (Workflow : AppEffects) (Either Text Value)
runDurableSkillStep deps profile overlays job decl sid prior selection path = do
  useObjectives <- Workflow.patch (Workflow.PatchId "shikigami-objective-tracking-v1")
  let runtime = executionRuntime deps
      loadObjectives = case deps.objectives of
        Nothing | isNothing job.objective -> pure (Right Nothing)
        Nothing -> pure (Left (Execution.ExecutionPolicyRefused "objective authority is unavailable"))
        Just host -> Objectives.resolveExecutionScope host job decl sid selection >>= objectiveAdmission
      coordinating = case decl.behavior of CoordinatingSkill {} -> True; _ -> False
      factory = executionTools deps
      describe snapshot
        | coordinating && isNothing deps.coordination = pure (Left (Execution.ExecutionPolicyRefused "coordinating Skill authority is unavailable"))
        | otherwise = do
            menu <- ExecutionTools.describeExecutionTools deps.logger deps.actionAuthorizer deps.capabilities.providers factory snapshot
            pure do
              admitted <- menu
              when (coordinating && not (any (\binding -> binding.name == Execution.executionCoordinate "workers") admitted.toolBindings)) (Left (Execution.ExecutionPolicyRefused "coordinating Skill scope was not admitted"))
              pure admitted
      assignment =
        ExecutionStart.SkillAssignment
          { runId = runJobWorkflowId job,
            agent = job.agentName,
            identity = job.identity,
            sessionId = sid,
            selection,
            sanctionedProfile = profile,
            capabilities = overlays,
            policy = Harness.narrowHarnessPolicy deps.harness decl.harness,
            skillDir = SkillDir (Text.unpack (declarationCoordinateText path)),
            input = pure (Right (ExecutionStart.SkillInput (BehaviorInput job.triggerPayload prior) []))
          }
  admitted <-
    if requestsWorkspace decl
      then
        runStep
          deps
          (StepName "admit-workspace-skill-execution")
          ( liftIO
              ( case deps.workspace of
                  Nothing -> pure (Left (Execution.ExecutionPolicyRefused "workspace host is unavailable"))
                  Just host -> if useObjectives then ExecutionStart.admitObjectiveWorkspaceSkillExecution (host.load assignment) loadObjectives runtime describe assignment else ExecutionStart.admitWorkspaceSkillExecution (host.load assignment) runtime describe assignment
              )
              >>= liftIO . executionResult
          )
      else runStep deps (StepName "admit-skill-execution") (liftIO ((if useObjectives then ExecutionStart.admitObjectiveSkillExecution loadObjectives runtime describe assignment else ExecutionStart.admitSkillExecution runtime describe assignment) >>= executionResult))
  case admitted of
    Left err -> pure (Left err)
    Right start -> do
      accepted <- ExecutionDriver.requestExecution runtime start
      liftIO (ExecutionStart.readExecutionResult runtime job.identity accepted >>= executionResult)
  where
    executionResult :: Either Execution.ExecutionError a -> IO (Either Text a)
    executionResult = \case
      Left Execution.ExecutionStorageUnavailable -> throwIO (TransientBehaviorFailure "execution storage unavailable")
      Left Execution.ProjectionUnavailable -> throwIO (TransientBehaviorFailure "execution projection unavailable")
      Left Execution.ExecutionRevisionConflict -> throwIO (TransientBehaviorFailure "execution admission changed concurrently")
      Left err -> pure (Left (boundedBehaviorDetail (Text.pack (show err))))
      Right value -> pure (Right value)

objectiveAdmission :: Either Objective.ObjectiveError a -> IO (Either Execution.ExecutionError a)
objectiveAdmission = \case
  Left Objective.ObjectiveUnavailable -> throwIO (TransientBehaviorFailure "objective authority unavailable")
  Left Objective.ObjectiveUnresolved -> throwIO (TransientBehaviorFailure "objective authority unresolved")
  Left err -> pure (Left (Execution.ExecutionPolicyRefused (Text.pack (show err))))
  Right value -> pure (Right value)

finishSuccessfulRun ::
  AgentRunDeps ->
  Text ->
  ApprovalPolicySnapshot ->
  ResolvedAgentIdentity ->
  RunJob ->
  AgentDecl ->
  SessionId ->
  [MemoryRecord] ->
  Value ->
  Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult)
finishSuccessfulRun deps selectedModelId approvalPolicyForRun recordedIdentity job decl sid prior output = do
  approvalResult <- approveSinks deps approvalPolicyForRun sid job decl output
  case approvalResult of
    Left err -> finishRunFailure deps recordedIdentity decl sid err
    Right approvedSinks -> do
      sinkResults <-
        withSpan' "sink.dispatch" (spanArgs Producer) \traceSpan -> do
          addAttribute traceSpan "agent.name" (agentDeclName decl)
          addAttribute traceSpan "sink.count" (length approvedSinks)
          enqueueSinkIntents
            (depsDirectory deps)
            (depsGrants deps)
            ((.agentName) job)
            ((.identity) job)
            (runJobOccurredAt job)
            (activityFromJob job)
            approvedSinks
            sid
            output
      liftIO (traverse_ (logSinkResult (depsLogger deps) job) sinkResults)
      recorded <- runStep deps (StepName "record") (requireStore (recordLearning deps recordedIdentity decl sid output))
      case recorded of
        StepRefused detail -> pure (Left (PermanentAgentRunFailure detail))
        StepProduced mem -> do
          completed <- runStep deps (StepName "complete") (requireStore (completeSession deps selectedModelId recordedIdentity sid))
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

finishRunFailure ::
  AgentRunDeps ->
  ResolvedAgentIdentity ->
  AgentDecl ->
  SessionId ->
  AgentRunFailure ->
  Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult)
finishRunFailure deps recordedIdentity decl sid err = do
  failed <- runStep deps (StepName "fail-session") (requireStore (failSession deps recordedIdentity decl sid (agentRunFailureDetail err)))
  pure case failed of
    StepProduced () -> Left err
    -- The run failed either way; if the failure could not be recorded, say
    -- both things rather than only the half that reached a store.
    StepRefused detail ->
      Left
        ( PermanentAgentRunFailure
            (agentRunFailureDetail err <> " (and " <> detail <> ")")
        )

capabilityScopeForRun :: RunJob -> CapabilityScope
capabilityScopeForRun job =
  CapabilityScope
    { runId = WorkflowRun (runJobWorkflowId job),
      -- C13 always binds to the identity admitted for this concrete run. The
      -- manifest principal remains part of pure catalog admission, but it must
      -- never replace a verified Meibo run principal at an IO boundary.
      principal = declarationCoordinate (either (const "") id (identityText ((.identity) job))),
      mode = Capability.Durable
    }

-- | Acquire the exact revisions from a journaled resolution, derive one
-- callback-local behavior environment, run the behavior, and release every
-- lease before returning.
runBehaviorWithCapabilities ::
  Log.Logger ->
  ActionAuthorizer ->
  CapabilityRuntime ->
  CapabilityScope ->
  ResolvedCapabilitySet ->
  BehaviorEnv ->
  AgentDecl ->
  BehaviorInput ->
  IO (Either CapabilityRuntimeError (Either RunError Value))
runBehaviorWithCapabilities logger actionAuthorizer CapabilityRuntime {providers} scope resolvedOverlays baseEnv@BehaviorEnv {tools = baseTools} decl input =
  withCapabilityOverlays
    logger
    actionAuthorizer
    providers
    scope
    resolvedOverlays
    baseTools
    (\registry _active -> runBehavior (withCapabilityTools resolvedOverlays registry baseEnv) decl input)

resolveRequiredProfile ::
  AgentRunDeps ->
  AgentDecl ->
  IO (Either ProfileResolutionError (Maybe ResolvedProfile))
resolveRequiredProfile deps AgentDecl {sanctionedProfile} =
  case sanctionedProfile of
    Nothing -> pure (Right Nothing)
    Just ProfileRequirement {profileId, version} ->
      fmap Just
        <$> (.resolveRunProfile)
          deps
          profileId
          version

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
    StepRefused detail -> Aeson.object [stepRefusedKey .= detail]

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
    liftIO ((.beforeStepBody) ((.hooks) deps) stepName)
    result <- action
    liftIO ((.afterStepBody) ((.hooks) deps) stepName)
    pure result

approveSinks ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  AgentRunDeps ->
  ApprovalPolicySnapshot ->
  SessionId ->
  RunJob ->
  AgentDecl ->
  Value ->
  Eff es (Either AgentRunFailure [Sink])
approveSinks deps approvalPolicyForRun sid job decl output = do
  decisions <- traverse (approveWithPolicy approvalPolicyForRun) indexedSinks
  pure (catMaybes <$> sequence decisions)
  where
    indexedSinks = zip [0 :: Int ..] ((.sinks) decl)

    approveWithPolicy policy (ordinal, sink)
      | not (requiresApprovalFor policy kind) = pure (Right (Just sink))
      | otherwise = do
          requested <-
            trySync
              ( ApprovalWorkflow.requestApproval
                  ("sink-" <> sinkKindText kind <> "-" <> Text.pack (show ordinal))
                  sid
                  ApprovalRequest
                    { prompt = "Approve " <> sinkKindText kind <> " sink for agent " <> (agentNameText ((.agentName) job)) <> "?",
                      context = output,
                      channel = approvalPolicyChannel policy
                    }
                  (approvalPolicyDeadline policy)
              )
          case requested of
            Left err ->
              case fromException err of
                Just (WorkflowChildFailed childName childId detail) ->
                  pure
                    ( Left
                        ( PermanentAgentRunFailure
                            ( "approval child "
                                <> Text.pack (show childName)
                                <> "/"
                                <> Text.pack (show childId)
                                <> " failed: "
                                <> detail
                            )
                        )
                    )
                Nothing -> EffException.throwIO err
            Right (ApprovalWorkflow.ApprovalNotificationFailed detail) ->
              pure (Left (PermanentAgentRunFailure ("approval notification failed: " <> detail)))
            Right (ApprovalWorkflow.ApprovalResolved decision) ->
              pure
                ( Right case decision of
                    Approved _ -> Just sink
                    Rejected _ -> Nothing
                    TimedOut -> Nothing
                )
      where
        kind = sinkKindOf sink

-- | Open the run's kioku session.
--
-- Neither of kioku's two answers is discarded any more. A run whose session was
-- never opened has no durable record to attach memories or a completion to, and
-- reporting success for it is a lie about what happened: an unreachable store
-- becomes the workflow driver's retryable store-error arm, and a refused command
-- becomes a journaled 'StepRefused' the caller turns into a permanent failure.
openSession :: (IOE :> es) => AgentRunDeps -> ResolvedAgentIdentity -> RunJob -> AgentDecl -> Eff es (Either StoreError (StepResult SessionId))
openSession deps recordedIdentity job decl = liftIO do
  startedAt' <- getCurrentTime
  sid <- genSessionId
  let sessionAgentId = resolvedIdentityText recordedIdentity
      focusTxt = behaviorKindText ((.behavior) decl)
      RunJob {parentSessionId = jobParentSessionId, delegationDepth = jobDelegationDepth} = job
  -- kioku answers with the session id it started, which is the one generated
  -- above; taking it from the answer keeps the step value the store's word.
  kiokuWrite "opening the run's kioku session" $
    Session.startWithContext
      (shikigamiWriteContext recordedIdentity)
      StartSessionData
        { sessionId = sid,
          memorySpaceId = shikigamiMemorySpace,
          actorPrincipal = agentActor recordedIdentity,
          ownerPrincipal = Nothing,
          agentId = sessionAgentId,
          focus = focusTxt,
          scope = agentScope recordedIdentity,
          subjectRef = Just (idText sid),
          previousSessionId = Nothing,
          parentSessionId = jobParentSessionId,
          delegationDepth = maybe 0 depthInt jobDelegationDepth,
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
  AgentRunDeps ->
  BehaviorEnv ->
  Maybe ResolvedProfile ->
  ApprovalPolicySnapshot ->
  ResolvedAgentIdentity ->
  SessionId ->
  AgentDecl ->
  RunJob ->
  [MemoryRecord] ->
  Eff (Workflow : AppEffects) (Either Text Value)
runBehaviorStep deps activeBehaviorEnv resolvedProfile approvalPolicyForRun recordedIdentity sid decl@AgentDecl {behavior = currentBehavior} job@RunJob {triggerPayload} prior =
  case currentBehavior of
    Flow {name = flowName} -> runFlowBehavior deps activeBehaviorEnv resolvedProfile approvalPolicyForRun recordedIdentity sid decl job flowName
    _
      | not (null ((.delegates) decl)) -> Right <$> runDeclaredSupervisor deps decl sid job
      | otherwise ->
          liftIO
            ( first (Text.pack . show)
                <$> runBehavior activeBehaviorEnv decl BehaviorInput {payload = triggerPayload, recalled = prior}
            )

runFlowBehavior ::
  AgentRunDeps ->
  BehaviorEnv ->
  Maybe ResolvedProfile ->
  ApprovalPolicySnapshot ->
  ResolvedAgentIdentity ->
  SessionId ->
  AgentDecl ->
  RunJob ->
  DeclarationCoordinate "flow" ->
  Eff (Workflow : AppEffects) (Either Text Value)
runFlowBehavior deps activeBehaviorEnv resolvedProfile approvalPolicyForRun recordedIdentity sid decl job flowName =
  case Flow.lookupFlow flowName of
    Nothing -> pure (Left ("unknown flow " <> declarationCoordinateText flowName))
    Just flow@Flow.FlowDef {Flow.run} -> do
      (_, childWorkflowId) <- currentWorkflow
      let coordinator = WorkerCapability.CoordinatorRun childWorkflowId job.identity sid job.executionRootId job.executionPermissions
      coordinationPolicy <- step (StepName "worker-coordination-policy") (liftIO (FlowWorkers.resolveCoordinationPolicy deps.coordination deps.actionAuthorizer coordinator))
      useObjectives <- Workflow.patch (Workflow.PatchId "shikigami-objective-tracking-v1")
      objectivePolicy <-
        if useObjectives
          then step (StepName "objectives-policy") do
            (nativeName, nativeRun) <- currentWorkflow
            generation <- Workflow.currentRunGeneration
            liftIO case deps.objectives of
              Nothing | isNothing job.objective -> pure (Right Nothing)
              Nothing -> pure (Left Objective.ObjectiveDenied)
              Just host ->
                Objectives.resolveFlowScope host nativeName nativeRun (toInteger generation) job sid (either (const Nothing) id coordinationPolicy) >>= \case
                  Left Objective.ObjectiveUnavailable -> throwIO (TransientBehaviorFailure "objective authority unavailable")
                  value -> pure value
          else pure (Right Nothing)
      let decisionTimeout = DecisionContract.parseDecisionTimeout (floor (durationTime (depsRunTimeout deps) * 1000000))
          attentionInterpreter = PracticeReviewAttention.runPracticeReviewAttentionAtomic practiceReviewAttentionEnv
          decisionInterpreter action
            | null flow.decisionSlots = FlowDecision.runDecisionDisabled action
            | Left refusal <- decisionTimeout = EffException.throwIO (DecisionAbort (DecisionContract.decisionFailure DecisionContract.InvalidSlot refusal))
            | Just pool <- (.deliveryPool) deps,
              Right timeout <- decisionTimeout =
                FlowDecision.runDecision
                  FlowDecision.DecisionEnv
                    { agent = decl,
                      inventory = flow.decisionSlots,
                      services = (.decisions) deps,
                      runtime = activeBehaviorEnv.runtime,
                      profile = resolvedProfile,
                      evidence = DecisionEvidence.postgresDecisionEvidenceStore pool,
                      routing = depsRouting deps,
                      timeoutMicros = timeout,
                      beforeStep = ((.hooks) deps).beforeStepBody,
                      afterStep = ((.hooks) deps).afterStepBody
                    }
                  action
            | otherwise = FlowDecision.runDecisionDisabled action
      attempted <-
        trySync
          ( FlowCapability.runActivity (activityFromJob job)
              . FlowCapability.runMemory memoryEnv
              . FlowCapability.runSink sinkEnv
              . FlowDelegate.runDelegate delegateEnv
              . FlowWorkers.runWorkers deps.coordination deps.actionAuthorizer coordinator coordinationPolicy
              . FlowObjectives.runObjectives deps.objectives objectivePolicy
              . FlowRouting.runRouting routingEnv
              . decisionInterpreter
              . acknowledgementInterpreter
              . PracticeReview.runExecutionContext (practiceReviewExecutionContext childWorkflowId)
              . PracticeReview.runPracticeReviewEvidence True ((.practiceReview) deps)
              . PracticeReview.runPracticeReviewEvaluator True activeBehaviorEnv ((.practiceReview) deps)
              . PracticeReviewMemory.runPracticeReviewMemory practiceReviewMemoryEnv
              . attentionInterpreter
              $ run ((.triggerPayload) job)
          )
      when (not (null flow.decisionSlots)) do
        forM_ ((.deliveryPool) deps) \pool -> do
          finalized <- liftIO (DecisionEvidence.finalizeDecisionReport (DecisionEvidence.postgresDecisionEvidenceStore pool) (runCorrelationId (jobIdempotencyKey job)))
          either (EffException.throwIO . DecisionAbort) (const (pure ())) finalized
      case attempted of
        Left err | Just (DecisionAbort failure) <- fromException err -> pure (Left (renderDecisionFailure failure))
        Left err ->
          case fromException err of
            Just (ApprovalAcknowledgementFailed detail) -> pure (Left detail)
            Nothing -> EffException.throwIO err
        Right output -> pure (Right output)
  where
    acknowledgementInterpreter =
      runAcknowledgementWithChild
        sid
        (approvalPolicyChannel approvalPolicyForRun)
        (approvalPolicyDeadline approvalPolicyForRun)
    memoryEnv =
      FlowCapability.MemoryEnv
        { FlowCapability.appEnv = (.appEnv) deps,
          FlowCapability.agent = decl,
          FlowCapability.identity = recordedIdentity,
          FlowCapability.aliasPool = (.deliveryPool) deps,
          FlowCapability.sessionId = Just sid
        }
    delegateEnv =
      FlowDelegate.DelegateEnv
        { FlowDelegate.agent = decl,
          FlowDelegate.context = delegateContext deps decl sid job,
          FlowDelegate.agents = (.agents) deps,
          FlowDelegate.directory = depsDirectory deps
        }
    routingEnv =
      FlowRouting.RoutingEnv
        { FlowRouting.agent = decl,
          FlowRouting.sessionId = sid,
          FlowRouting.behaviorEnv = activeBehaviorEnv,
          FlowRouting.runtime = depsRouting deps
        }
    sinkEnv =
      FlowCapability.SinkEnv
        { FlowCapability.agent = (.agentName) job,
          FlowCapability.runId = sid,
          FlowCapability.occurredAt = Just (runJobOccurredAt job),
          FlowCapability.danwaTarget = Nothing,
          FlowCapability.activity = Just (activityFromJob job),
          FlowCapability.grants = depsGrants deps,
          FlowCapability.directory = depsDirectory deps,
          FlowCapability.identity = (.identity) job
        }
    practiceReviewExecutionContext childWorkflowId =
      PracticeReview.PracticeReviewExecutionContext
        { PracticeReview.identity = (.identity) job,
          PracticeReview.parentWorkflowId = (.parentRunWorkflowId) job,
          PracticeReview.parentSessionId = (.parentSessionId) job,
          PracticeReview.childWorkflowId = childWorkflowId,
          PracticeReview.childSessionId = sid
        }
    practiceReviewMemoryEnv =
      PracticeReviewMemory.PracticeReviewMemoryEnv
        { PracticeReviewMemory.appEnv = (.appEnv) deps,
          PracticeReviewMemory.agent = decl,
          PracticeReviewMemory.identity = recordedIdentity,
          PracticeReviewMemory.sessionId = Just sid
        }
    practiceReviewAttentionEnv =
      PracticeReviewAttention.PracticeReviewAttentionEnv
        { PracticeReviewAttention.agent = (.agentName) job,
          PracticeReviewAttention.identity = (.identity) job,
          PracticeReviewAttention.runId = sid,
          PracticeReviewAttention.occurredAt = Just (runJobOccurredAt job),
          PracticeReviewAttention.activity = Just (activityFromJob job),
          PracticeReviewAttention.grants = depsGrants deps,
          PracticeReviewAttention.directory = depsDirectory deps,
          PracticeReviewAttention.recipients = (.attentionRecipients) ((.practiceReview) deps)
        }

activityFromJob :: RunJob -> Activity.ActivityEnvelope
activityFromJob job@RunJob {triggerPayload} =
  case Aeson.fromJSON triggerPayload of
    Aeson.Success activity -> activity
    Aeson.Error _ -> syntheticActivityFromJob job

syntheticActivityFromJob :: RunJob -> Activity.ActivityEnvelope
syntheticActivityFromJob RunJob {agentName, occurredAt, triggerPayload, idempotencyKey} =
  Activity.ActivityEnvelope
    { Activity.activityId = Activity.activityCoordinate (runKeyText idempotencyKey),
      Activity.occurredAt = Activity.activityCoordinate (Text.pack (iso8601Show occurredAt)),
      Activity.source = Activity.activityCoordinate "shinzui/shikigami",
      Activity.actor = Activity.Actor {Activity.kind = Activity.ServiceActor, Activity.id = Activity.activityCoordinate (agentNameText agentName), Activity.session = Nothing},
      Activity.subject = Activity.Subject {Activity.kind = Activity.activityCoordinate "run", Activity.subjectId = Activity.activityCoordinate (runKeyText idempotencyKey)},
      Activity.verb = Activity.activityCoordinate "run.triggered",
      Activity.payload = triggerPayload,
      Activity.contextRefs = [],
      Activity.idempotencyKey = Activity.activityCoordinate (runKeyText idempotencyKey)
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
      delegationKey ordinal = declarationCoordinate ("delegate-" <> Text.pack (show ordinal))
      resultLabel target = let raw = agentNameText target in fromMaybe raw (Text.stripSuffix "-researcher" raw)
      childPayload target =
        Aeson.object
          [ (.=) "role" (resultLabel target),
            (.=) "input" triggerPayload
          ]
  childHandles <-
    traverse
      (\(ordinal, target) -> delegate ((.agents) deps) (depsDirectory deps) decl ctx (delegationKey ordinal) target (childPayload target))
      (zip [(0 :: Int) ..] delegateTargets)
  findings <- awaitAllDelegated childHandles
  pure
    ( Aeson.object
        ( (.=) "summary" (agentDeclName decl <> " synthesized delegated findings")
            : zipWith
              (\target finding -> (.=) (Key.fromText (resultLabel target)) (either Aeson.String id finding))
              delegateTargets
              findings
        )
    )

delegateContext :: AgentRunDeps -> AgentDecl -> SessionId -> RunJob -> DelegateCtx
delegateContext deps decl currentSession RunJob {agentName, identity, parentSessionId, parentRunWorkflowId, delegationDepth, lineage, delegationBudgetId, executionRootId, executionPermissions} =
  DelegateCtx
    { depth = fromMaybe initialDepth delegationDepth,
      identity,
      sessionId = Just currentSession,
      parentSessionId,
      parentRunWorkflowId,
      lineage = if null lineage then [agentName] else lineage,
      delegationBudgetId,
      executionRootId,
      executionPermissions,
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
failSession :: (IOE :> es) => AgentRunDeps -> ResolvedAgentIdentity -> AgentDecl -> SessionId -> Text -> Eff es (Either StoreError (StepResult ()))
failSession deps recordedIdentity decl@AgentDecl {memory = MemoryPolicy {recordPolicy}} sid err = liftIO do
  when (recordPolicy == Always) $
    recordFailureLearningBestEffort deps recordedIdentity decl sid err
  failedAt' <- getCurrentTime
  kiokuWrite "marking the run's kioku session failed" $
    (fmap . fmap) void $
      Session.failSessionWithContext
        (shikigamiWriteContext recordedIdentity)
        FailSessionData
          { sessionId = sid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor recordedIdentity,
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
recordFailureLearningBestEffort :: AgentRunDeps -> ResolvedAgentIdentity -> AgentDecl -> SessionId -> Text -> IO ()
recordFailureLearningBestEffort deps recordedIdentity decl sid err = do
  recorded <-
    recordMemory
      deps
      recordedIdentity
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
        [ "agent" .= agentDeclName decl,
          "write" .= ("failure_learning" :: Text),
          "error" .= detail
        ]

publishSinkIntent :: (IOE :> es) => AgentRunDeps -> OutboxRow -> Eff es PublishOutcome
publishSinkIntent AgentRunDeps {appEnv = depsAppEnv, kizashi = depsKizashi, kawa = depsKawa, kanmon = depsKanmon, danwa = depsDanwa, rei = depsRei, http = sinkHttp, logger = intentLogger, grants = rawIntentGrants, actionAuthorizer, directory = intentDirectory, deliveryPool} row =
  let OutboxRow {event = integrationEvent} = row
   in case decodeSinkIntentEvent integrationEvent of
        Left err -> pure (PublishFailed (Text.pack (show err)))
        Right intent@SinkIntent {agent, identity = recordedIdentity, runId, ordinal, occurredAt, danwaTarget, resolvedRecipient, conversationKey, triggeringActivityId, sink, output} -> liftIO do
          let messageId = Integration.messageId integrationEvent
              kind = sinkKindOf sink
              publish =
                Otel.inSpan' (depsAppEnv.tracer) "sink.publish" (spanArgs Consumer) \traceSpan -> do
                  Otel.addAttribute traceSpan "sink.kind" (Otel.toAttribute (sinkKindText kind))
                  currentTraceContext <- traceContextFromCurrentSpan
                  admittedIdentity <- case recordedIdentity of
                    UnresolvedLegacyIdentity ->
                      Directory.identityAdmission intentDirectory Nothing agent
                    _ -> pure (Right recordedIdentity)
                  let sinkContext =
                        SinkContext
                          { identity = either (const recordedIdentity) id admittedIdentity,
                            directory = intentDirectory,
                            runId = runId,
                            ordinal = ordinal,
                            kizashi = depsKizashi,
                            kawa = depsKawa,
                            kanmon = depsKanmon,
                            danwa = depsDanwa,
                            rei = depsRei,
                            http = sinkHttp,
                            traceHeaders = maybe [] TraceContext.traceHeaders currentTraceContext,
                            danwaTarget = danwaTarget,
                            recipientOverride = resolvedRecipient,
                            conversationKey,
                            triggeringActivityId,
                            occurredAt = occurredAt,
                            receipts = (\pool -> deliveryGuard pool messageId kind intent) <$> deliveryPool,
                            grants = withActionAuthorizer actionAuthorizer rawIntentGrants,
                            logger = intentLogger
                          }
                      send = case admittedIdentity of
                        Left reason -> pure (SinkResult kind (SkippedLifecycle reason))
                        Right _ -> dispatch sinkContext sink output
                  case deliveryPool of
                    Nothing -> publishUntracked <$> send
                    Just pool -> publishTracked intentLogger pool messageId kind intent send
          case Integration.traceContext integrationEvent of
            Nothing -> publish
            Just storedContext -> do
              (continued, result) <- TraceContext.withRemoteTraceContext storedContext publish
              unless continued $
                Log.logWarn
                  intentLogger
                  "sink.trace_context.invalid"
                  ["outbox_message_id" .= messageId]
              pure result

publishUntracked :: SinkResult -> PublishOutcome
publishUntracked result = case (.outcome) result of
  Failed err -> PublishFailed err
  AuthorizationFailed err -> PublishFailed err
  PermanentFailure err -> either PublishFailed id (permanentPublishOutcome err)
  Enqueued detail -> PublishFailed ("dispatcher returned enqueue-only outcome during publish: " <> declarationCoordinateText detail)
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
  existing <- Delivery.lookupDeliveryFor pool (deliveryContextFor messageId kind intent) (Delivery.deliveryReceiptKey messageId)
  case existing of
    Left err -> do
      logReceiptError logger "sink.delivery.lookup_failed" messageId kind err
      pure (PublishFailed ("delivery receipt lookup failed: " <> err))
    Right (Just Delivery.DeliveryReceipt {Delivery.status = Delivery.Delivered}) -> do
      Log.logInfo
        logger
        "sink.delivery.skipped"
        [ "outbox_message_id" .= messageId,
          "sink_kind" .= sinkKindText kind,
          "reason" .= ("proven-delivered" :: Text)
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

    finish result = case (.outcome) result of
      Delivered downstreamId -> do
        recordReceipt Delivery.Delivered (Just (declarationCoordinateText downstreamId)) >>= \case
          Right () -> pure PublishSucceeded
          Left err -> do
            unknownResult <- recordReceipt Delivery.Unknown (Just ("downstream acknowledged, receipt commit failed: " <> err))
            Log.logError
              logger
              "sink.delivery.unknown"
              [ "outbox_message_id" .= messageId,
                "sink_kind" .= sinkKindText kind,
                "downstream_id" .= downstreamId,
                "receipt_error" .= err,
                "unknown_write" .= either id (const ("recorded" :: Text)) unknownResult
              ]
            -- A retry here would knowingly repeat an acknowledged downstream
            -- effect. Keiro may publish the outbox row; the critical unknown
            -- event is the operator-visible repair target.
            pure PublishSucceeded
      Failed err -> recordRetryableFailure err
      AuthorizationFailed err -> recordRetryableFailure err
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
      Enqueued detail -> recordRetryableFailure ("dispatcher returned enqueue-only outcome during publish: " <> declarationCoordinateText detail)
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
    [ "outbox_message_id" .= messageId,
      "sink_kind" .= sinkKindText kind,
      "error" .= err
    ]

deliveryGuard :: Pool -> Text -> SinkKind -> SinkIntent -> DeliveryGuard
deliveryGuard pool messageId kind intent =
  DeliveryGuard
    { lookupReceipt = \substep -> do
        lookedUp <- Delivery.lookupDeliveryFor pool (deliveryContextFor messageId kind intent) (Delivery.subReceiptKey messageId (declarationCoordinateText substep))
        case lookedUp of
          Left err -> receiptIoError "lookup" err
          Right (Just Delivery.DeliveryReceipt {Delivery.status = Delivery.ConversationStarted, Delivery.detail = Just (Delivery.DownstreamReference recorded)}) -> pure (Just (declarationCoordinate (declarationCoordinateText recorded)))
          Right Nothing -> pure Nothing
          Right (Just _) -> receiptIoError "lookup" "inconsistent retained conversation receipt",
      recordReceipt = \substep recorded -> do
        now <- getCurrentTime
        let receipt =
              deliveryReceiptForKey
                (Delivery.subReceiptKey messageId (declarationCoordinateText substep))
                messageId
                kind
                Delivery.ConversationStarted
                (Just (declarationCoordinateText recorded))
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
  case decodeSinkIntentEvent integrationEvent of
    Left err ->
      Log.logError
        logger
        "sink.delivery.reconciliation_decode_failed"
        [ "outbox_message_id" .= messageId,
          "error" .= Text.pack (show err)
        ]
    Right intent@SinkIntent {sink} -> do
      let kind = sinkKindOf sink
      Delivery.lookupDeliveryFor pool (deliveryContextFor messageId kind intent) (Delivery.deliveryReceiptKey messageId) >>= \case
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
                [ "outbox_message_id" .= messageId,
                  "sink_kind" .= sinkKindText kind
                ]

-- | Record the run's learning, if the declared policy asks for one.
--
-- A declaration that says @recordPolicy = Always@ and a run that reports success
-- having persisted nothing disagree about what the agent did. The store result
-- is therefore returned, not discarded; 'requireStore' at the call site fails the
-- run instead.
recordLearning :: (IOE :> es) => AgentRunDeps -> ResolvedAgentIdentity -> AgentDecl -> SessionId -> Value -> Eff es (Either StoreError (StepResult (Maybe MemoryId)))
recordLearning deps recordedIdentity decl@AgentDecl {memory = MemoryPolicy {recordPolicy}} sid output = liftIO do
  case recordPolicy of
    Never -> pure (Right (StepProduced Nothing))
    OnSuccess -> recordedJust
    Always -> recordedJust
  where
    recordedJust = (fmap . fmap) (fmap Just) recordSuccess

    recordSuccess =
      recordMemory
        deps
        recordedIdentity
        decl
        sid
        (renderLearning output)
        (Set.fromList ["agent-run", behaviorKindText ((.behavior) decl)])

recordMemory :: AgentRunDeps -> ResolvedAgentIdentity -> AgentDecl -> SessionId -> Text -> Set.Set Text -> IO (Either StoreError (StepResult MemoryId))
recordMemory deps recordedIdentity decl sid content' tags' = do
  mid <- genMemoryId
  recordedAt' <- getCurrentTime
  kiokuWrite "recording the run's learning" $
    Memory.recordWithContext
      (shikigamiWriteContext recordedIdentity)
      RecordMemoryData
        { memoryId = mid,
          memorySpaceId = shikigamiMemorySpace,
          actorPrincipal = agentActor recordedIdentity,
          ownerPrincipal = Nothing,
          agentId = agentDeclName decl,
          sessionId = Just sid,
          scope = agentScope recordedIdentity,
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
completeSession :: (IOE :> es) => AgentRunDeps -> Text -> ResolvedAgentIdentity -> SessionId -> Eff es (Either StoreError (StepResult ()))
completeSession deps selectedModelId recordedIdentity sid = liftIO do
  completedAt' <- getCurrentTime
  kiokuWrite "completing the run's kioku session" $
    (fmap . fmap) void $
      Session.completeWithContext
        (shikigamiWriteContext recordedIdentity)
        CompleteSessionData
          { sessionId = sid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor recordedIdentity,
            completedAt = completedAt',
            modelUsed = Just selectedModelId,
            summary = Just "agent-run completed"
          }
        & runKioku deps

runKioku :: AgentRunDeps -> Eff AppEffects a -> IO (Either StoreError a)
runKioku deps = runAppIO deps.appEnv

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
    (levelFor ((.outcome) result))
    "sink.result"
    ( [ "agent" .= (agentNameText ((.agentName) job)),
        Log.runIdKey .= (runJobWorkflowId job).unWorkflowId,
        "sink_kind" .= sinkKindText ((.kind) result),
        "outcome" .= outcomeText ((.outcome) result)
      ]
        <> detailField ((.outcome) result)
    )
  where
    levelFor = \case
      Failed _ -> Log.Error
      PermanentFailure _ -> Log.Error
      AuthorizationFailed _ -> Log.Error
      DeniedOutcome _ -> Log.Warn
      SkippedLifecycle _ -> Log.Warn
      _ -> Log.Info
    outcomeText :: SinkOutcome -> Text
    outcomeText = \case
      Delivered _ -> "delivered"
      Enqueued _ -> "enqueued"
      Stubbed -> "stubbed"
      DeniedOutcome _ -> "denied"
      AuthorizationFailed _ -> "authorization_failed"
      SkippedLifecycle _ -> "skipped_lifecycle"
      Failed _ -> "failed"
      PermanentFailure _ -> "permanent_failure"
    -- The detail rides under a key that says what kind of detail it is, so that
    -- a query for failures can read @error@ without also matching the returned
    -- id of a successful delivery.
    detailField = \case
      Delivered detail -> ["detail" .= detail]
      Enqueued detail -> ["detail" .= detail]
      Stubbed -> []
      DeniedOutcome reason -> ["reason" .= reason]
      AuthorizationFailed reason -> ["error" .= reason]
      SkippedLifecycle reason -> ["reason" .= reason]
      Failed err -> ["error" .= err]
      PermanentFailure err -> ["error" .= err]

triggerKindText :: Trigger -> Text
triggerKindText = \case
  Schedule {} -> "schedule"
  Stream {} -> "stream"
  Event {} -> "event"

spanArgs :: SpanKind -> SpanArguments
spanArgs spanKind =
  Otel.defaultSpanArguments {Otel.kind = spanKind}
