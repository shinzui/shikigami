{-# LANGUAGE DataKinds #-}

-- | Trusted composition over accepted native admission and the objective owner.
-- A model never constructs this runtime or an admitted catalog.
module Shikigami.Coordination.Runtime
  ( Runtime (..),
    admit,
    validateAdmission,
    host,
    owned,
    checkpoint,
    accept,
    decisionEnv,
    decisionHost,
    mark,
    graphMark,
    operationKey,
    fresh,
    note,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.List (find, nub)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (Eff)
import Keiro.Workflow (StepName, loadStepIndex)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.CoordinationSource
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.Agent.DeclarationValue (agentEnabled, declarationCoordinate)
import Shikigami.Agent.Delegate.Context
import Shikigami.Agent.Delegate.Depth (depthInt, initialDepth)
import Shikigami.Agent.RunJob (RunJob (..))
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.App (AppEffects, runAppIO)
import Shikigami.Attestation.PolicyValue (mkCeiling)
import Shikigami.Attestation.Resolve (ResolvedProfile)
import Shikigami.Behavior.Run (BehaviorEnv (..))
import Shikigami.Capability.Overlay (emptyResolvedCapabilitySet)
import Shikigami.Coordination.Checkpoint qualified as CP
import Shikigami.Coordination.Decision
import Shikigami.Coordination.Identity
import Shikigami.Coordination.Proposal qualified as P
import Shikigami.Coordination.Sql qualified as Sql
import Shikigami.Coordination.Types
import Shikigami.Decision.Contract
import Shikigami.Decision.Evidence (DecisionEvidenceStore)
import Shikigami.Decision.Execution
import Shikigami.Decision.ModelCatalog (modelDescriptor)
import Shikigami.Directory qualified as Directory
import Shikigami.Execution.AssignmentKey (assignmentIdFor)
import Shikigami.Execution.Capacity qualified as Capacity
import Shikigami.Execution.Executor (ExecutionRuntime)
import Shikigami.Execution.Identity (OperationId, operationIdWithPrefix)
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Request (ExecutionPolicy (..))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Selection qualified as Selection
import Shikigami.Execution.Transcript hiding (OperationId)
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Routing (RoutingRuntime)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Capability qualified as Owner
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Runtime qualified as Objectives
import Shikigami.Objective.Store qualified as Goals
import Shikigami.Objective.Types
import Shikigami.Prelude hiding ((.=))
import Shikigami.WorkerSession.Capability (CoordinationHost (..), CoordinatorRun (..))
import Shikigami.WorkerSession.Handoff (TransferServices (..))
import Shikigami.WorkerSession.Workflow (SessionRuntime (..))
import Shikigami.Workspace.Store qualified as Workspace

data Runtime = Runtime
  { objectives :: !Objectives.ObjectiveRuntime,
    workers :: !CoordinationHost,
    execution :: !ExecutionRuntime,
    decisions :: !Decision.DecisionServices,
    behavior :: !BehaviorEnv,
    evidence :: !DecisionEvidenceStore,
    routing :: !RoutingRuntime,
    timeout :: !DecisionTimeout,
    budget :: !Agent.DelegationBudget,
    beforeStep :: !(StepName -> IO ()),
    afterStep :: !(StepName -> IO ())
  }

host :: Runtime -> Admission -> Owner.ObjectiveHost
host runtime admission = Objectives.hostFor runtime.objectives admission.run.identity

owned :: Runtime -> Eff AppEffects (Either ObjectiveError a) -> IO (Either ObjectiveError a)
owned runtime = Objectives.owned runtime.objectives

operationKey :: Text -> Aeson.Value -> OperationId
operationKey prefix value = operationIdWithPrefix ('a' :| "daptive:") (prefix <> ":" <> versionedDigest ("shikigami.adaptive-" <> prefix <> "/1") value)

-- Pin the native declaration, finite transitive catalog, model policy and
-- resource cutoff before the first model decision. No work is dispatched here.
admit :: Runtime -> CoordinatorRun -> Maybe ResolvedProfile -> HarnessPolicy -> DecisionPolicySnapshot -> Value -> IO (Either ObjectiveError Admission)
admit runtime origin profile harness decisions request = do
  source <- owned runtime $ first (const ObjectiveDenied) <$> loadAcceptedCoordinator origin
  recorded <- runAppIO runtime.objectives.appEnv (loadStepIndex agentRunWorkflowName origin.runId 0)
  case source of
    Left err -> pure (Left err)
    Right accepted -> case accepted.job.objective of
      Nothing -> pure (Left ObjectiveDenied)
      Just objective -> do
        current <- owned runtime (Owner.readObjective (Objectives.hostFor runtime.objectives origin.identity) objective.objectiveId)
        root <- case origin.rootId of
          Nothing -> pure (Left ObjectiveDenied)
          Just root -> owned runtime (first (const ObjectiveDenied) <$> Roots.inspectRoot root)
        capacity <- owned runtime (runTransaction Capacity.inspectTx <&> first (const ObjectiveUnavailable))
        catalog <- catalogFor runtime accepted
        now <- getCurrentTime
        pure $ do
          goal <- current
          root <- root
          rootId <- maybe (Left ObjectiveDenied) Right origin.rootId
          capacity <- capacity
          targets <- catalog
          original <-
            first (const ObjectiveUnavailable) recorded >>= \steps -> case Map.lookup "decision-policy" steps of
              Just raw | Aeson.Success (Right policy) <- Aeson.fromJSON @(Either DecisionFailure DecisionPolicySnapshot) raw -> Right policy
              _ -> Left ObjectiveDenied
          unless (decisions == original && decisions.slots == adaptiveSlots && case accepted.agent.behavior of Agent.Flow {name} -> name == declarationCoordinate "adaptive-delivery"; _ -> False) (Left ObjectiveDenied)
          parent <- maybe (Left ObjectiveMissing) Right (find ((== objective.assignmentId) . (.definition.assignmentId)) goal.assignments)
          unless (goal.status == Open && parent.definition.owner == origin.identity && parent.definition.state `notElem` [Done, Withdrawn] && maybe True (\bound -> Just bound == origin.rootId) parent.definition.rootId) (Left ObjectiveDenied)
          first (const ObjectiveDenied) (Resources.checkRoot now root.revision root)
          let limit = case accepted.agent.delegationBudget of Just declared | Agent.delegationBudgetNatural declared < Agent.delegationBudgetNatural runtime.budget -> declared; _ -> runtime.budget
              depth = fromMaybe initialDepth accepted.job.delegationDepth
              context = DelegateCtx depth origin.identity (Just origin.sessionId) accepted.job.parentSessionId accepted.job.parentRunWorkflowId (if null accepted.job.lineage then [accepted.agent.name] else accepted.job.lineage) origin.permittedAliases origin.rootId (Just (fromMaybe (Goals.coordinatorBudgetId objective.objectiveId origin.identity) accepted.job.delegationBudgetId)) limit
              admittedTargets = [target | target <- targets, any (\member -> member.principal == RecordedAgent target.identity && any (`elem` member.roles) [Owner, Coordinator, Worker]) goal.members]
              cutoff = maybe root.envelope.cutoff (min root.envelope.cutoff) parent.definition.cutoff
              policy = P.Policy V1 accepted.agent.name origin.identity rootId cutoff admittedTargets [] (max 1 (maxDelegationDepth - depthInt depth - 1)) (max 1 (min 128 (fromIntegral (Agent.delegationBudgetNatural limit)))) (Capacity.capacityLimit capacity.maximum)
              run = origin & #runId .~ adaptiveWorkflowId origin objective
          pure (Admission origin run objective parent.ownerEpoch accepted.agent (accepted.agent : filter (\decl -> decl.name `elem` map (.name) admittedTargets) runtime.workers.services.sessions.agents) context policy decisions profile harness (DecisionWorkLimits runtime.timeout (either (error . show) id (mkCeiling 64))) (Text.take 16384 (accepted.agent.description <> "\nDeliver this finite objective using governed capabilities and exact integrated checks.")) request)

catalogFor :: Runtime -> AcceptedCoordinator -> IO (Either ObjectiveError [P.Target])
catalogFor runtime accepted = do
  let declarations = runtime.workers.services.sessions.agents
      reachable seen [] = seen
      reachable seen (name : rest)
        | name == accepted.agent.name || name `elem` map (.name) seen = reachable seen rest
        | otherwise = case find (\decl -> decl.name == name && agentEnabled decl.enabled) declarations of
            Nothing -> reachable seen rest
            Just decl -> reachable (seen <> [decl]) (rest <> decl.delegates)
      selected = reachable [] accepted.agent.delegates
  if length selected > 128
    then pure (Left (ObjectiveInvalid "adaptive catalog exceeds its bound"))
    else do
      targets <- forM selected $ \decl -> do
        identity <- Directory.identityAdmission runtime.objectives.directory ((.principal) <$> decl.identity) decl.name
        let parents = [parent.name | parent <- accepted.agent : selected, decl.name `elem` parent.delegates]
            models = case decl.execution of
              Just permission -> permission.permittedAliases
              Nothing -> either (const []) (pure . (.alias) . modelDescriptor) (Selection.defaultBinding runtime.behavior.model runtime.behavior.options)
            allowed = maybe models (\bound -> filter (`elem` bound) models) accepted.run.permittedAliases
        pure $ case identity of
          Right identity | not (null allowed) -> Just (P.Target decl.name identity parents allowed)
          _ -> Nothing
      pure (Right (mapMaybe id targets))

-- Child admission is a receipt from its native parent's journal. Resume may
-- refuse current authority, but it cannot substitute a larger live catalog.
validateAdmission :: Runtime -> Admission -> IO (Either ObjectiveError ())
validateAdmission runtime admission = do
  source <- runAppIO runtime.objectives.appEnv (loadStepIndex agentRunWorkflowName admission.origin.runId 0)
  pure $ do
    steps <- first (const ObjectiveUnavailable) source
    actual <- maybe (Left ObjectiveDenied) Right (Map.lookup "adaptive-admission" steps)
    unless (actual == toJSON (Right admission :: Either ObjectiveError Admission) && admission.run.runId == adaptiveWorkflowId admission.origin admission.objective) (Left ObjectiveDenied)

fresh :: Runtime -> Admission -> IO (Either ObjectiveError ())
fresh runtime admission = do
  available <- Directory.identityLifecycleAdmission runtime.objectives.directory admission.run.identity
  case available of
    Left _ -> pure (Left ObjectiveDenied)
    Right () -> owned runtime $ do
      access <- liftIO (Owner.admitObjectiveAction (host runtime admission) "adaptive-current-authority" (toJSON (admission.run, admission.objective)))
      case access of
        Left err -> pure (Left err)
        Right access ->
          Goals.coordinationQuery
            access
            admission.objective.objectiveId
            ( \goal -> pure $ do
                unless (Goals.mayCoordinate access goal && goal.status == Open) (Left ObjectiveDenied)
                assignment <- maybe (Left ObjectiveMissing) Right (find ((== admission.objective.assignmentId) . (.definition.assignmentId)) goal.assignments)
                unless (assignment.definition.owner == admission.run.identity && assignment.ownerEpoch == admission.ownerEpoch && assignment.definition.state `notElem` [Done, Withdrawn] && maybe True (== admission.organization.rootId) assignment.definition.rootId) (Left ObjectiveDenied)
            )
            <&> (>>= id)

checkpoint :: Runtime -> Admission -> CP.Provider
checkpoint runtime admission =
  let provider = CP.checkpointProvider runtime.objectives.appEnv (host runtime admission) admission.organization (fresh runtime admission)
   in provider
        { CP.current = \objective ->
            provider.current objective >>= \case
              Left err -> pure (Left err)
              Right checkpoint -> do
                references <- owned runtime do
                  grant <- liftIO (Owner.admitObjectiveAction (host runtime admission) "adaptive-workspace-references" (toJSON objective))
                  case grant of
                    Left err -> pure (Left err)
                    Right access ->
                      Goals.coordinationQuery
                        access
                        objective
                        ( \goal -> do
                            if goal.revision /= checkpoint.objective.revision
                              then pure (Left ObjectiveConflict)
                              else do
                                entries <- forM goal.assignments \assignment -> case assignment.definition.sessionId of
                                  Nothing -> pure (Right [])
                                  Just _ | isNothing runtime.workers.services.workspaces -> pure (Right [])
                                  Just session -> Workspace.sessionWorkspaceTx session admission.organization.rootId assignment.definition.owner assignment.ownerEpoch <&> either (const (Left ObjectiveUnavailable)) (Right . maybe [] (\reference -> [(assignment.definition.assignmentId, reference)]))
                                pure (concat <$> sequence entries)
                        )
                        <&> (>>= id)
                pure ((\workspaces -> checkpoint {CP.workspaces = workspaces}) <$> references)
        }

decisionEnv :: Runtime -> Admission -> Decision.DecisionEnv
decisionEnv runtime admission = Decision.DecisionEnv admission.declaration adaptiveSlots runtime.decisions runtime.behavior.runtime admission.profile runtime.evidence runtime.routing admission.decisionLimits.timeout runtime.beforeStep runtime.afterStep

decisionHost :: Runtime -> Admission -> Decision.AcceptedDecisionHost
decisionHost runtime admission = Decision.AcceptedDecisionHost runtime.execution admission.run.identity $ \prepared parameters ->
  admitBoundedDecisionExecution admission.decisionLimits runtime.execution admission.run.identity prepared $ do
    state <- parameters
    now <- getCurrentTime
    pure $ do
      unless (prepared.workflowId == admission.run.runId && prepared.policy == admission.decisions.policy && any (== prepared.model) admission.decisions.models) (Left ExecutionIdentityConflict)
      let alias = prepared.model.alias
          assignment = assignmentIdFor ("typed-decision:" <> decisionPreparationIdText prepared.identity)
      selected <- first (const (ExecutionPolicyRefused "pinned decision-only selection unavailable")) (Selection.resolveExecutionSelection assignment runtime.decisions.catalog (Left Selection.ExecutionAliasUnavailable) (Just (ExecutionPolicy alias [alias])) Nothing Nothing admission.profile (Just admission.organization.rootId) now)
      unless (selected.descriptor == prepared.model) (Left ExecutionIdentityConflict)
      let snapshot = ExecutionSnapshot V1 (decisionExecutionId prepared) admission.run.runId admission.declaration.name admission.run.identity admission.run.sessionId selected admission.profile (SkillInstructions (executionCoordinate "adaptive-decision") "Typed adaptive coordinator" admission.instructions) (ReplayContext RequestContext Nothing [RequestTurn [TextBlock "Accepted typed adaptive decision"] Nothing]) emptyResolvedCapabilitySet (toJSON ([] :: [Value])) admission.harness [] Nothing Nothing
      pure (snapshot, state)

mark :: Objective -> EvidenceMark
mark objective = EvidenceMark objective.instructionsRevision objective.criteriaRevision (graphMark (map (.definition) objective.assignments)) objective.nextActions (map (versionedDigest "shikigami.adaptive-finding/1" . toJSON) objective.reportedResults) (map (.input.key) objective.evidence) objective.unresolved

-- Fresh dispatch availability narrows the retained catalog. The provider's
-- committed-decision lookup still runs first, so history survives revocation.
accept :: Runtime -> Admission -> CP.Checkpoint -> P.Proposal -> IO (Either ObjectiveError P.AcceptedDecision)
accept runtime admission checkpoint proposal =
  (CP.checkpointProvider runtime.objectives.appEnv (host runtime admission) (admission.organization & #workspaces .~ checkpoint.workspaces) available).accept proposal
  where
    available = do
      root <- fresh runtime admission
      targets <- forM names $ \name -> case find (\decl -> decl.name == name && agentEnabled decl.enabled) runtime.workers.services.sessions.agents of
        Nothing -> pure (Left ObjectiveDenied)
        Just decl -> do
          current <- Directory.identityAdmission runtime.objectives.directory ((.principal) <$> decl.identity) name
          pure $ do
            identity <- first (const ObjectiveDenied) current
            pinned <- maybe (Left ObjectiveDenied) Right (find ((== name) . (.name)) admission.organization.targets)
            unless (identity == pinned.identity) (Left ObjectiveDenied)
      pure (root >> (() <$ sequence targets))
    named key = maybe [] (pure . (.target)) (find ((== key) . (.assignment.assignmentId)) checkpoint.arrangement)
    names = nub (concatMap (\case P.CreateAssignment placement -> [placement.target]; P.SplitAssignment _ placements -> map (.target) placements; P.ConsolidateAssignments _ placement -> [placement.target]; P.TransferAssignment _ name _ -> [name]; P.DirectWork key _ -> named key; P.FollowUpContext key _ -> named key; P.EscalateModel key _ -> named key; _ -> []) proposal.changes)

graphMark :: [AssignmentDraft] -> [Text]
graphMark = map (versionedDigest "shikigami.adaptive-graph-mark/1" . toJSON . (\draft -> draft & #sessionId .~ Nothing))

-- Terminal metadata has the native admission as its authority and a stable key.
-- The protected result remains in the workflow; diagnostics are coarse codes.
note :: Runtime -> Admission -> OperationId -> DeliveryResult -> IO (Either ObjectiveError ())
note runtime admission operation result = do
  valid <- validateAdmission runtime admission
  case valid of
    Left err -> pure (Left err)
    Right () -> owned runtime do
      grant <- liftIO (Owner.admitObjectiveAction (host runtime admission) "adaptive-terminal" (toJSON (operation, result.status)))
      case grant of
        Left err -> pure (Left err)
        Right access -> Goals.coordinationQuery access admission.objective.objectiveId (\goal -> if Goals.mayCoordinate access goal then Sql.saveObservation goal.objectiveId operation "terminal" result.revision result.status ("AdaptiveRefused" <$ result.refusal) >> pure (Right ()) else pure (Left ObjectiveDenied)) <&> (>>= id)
