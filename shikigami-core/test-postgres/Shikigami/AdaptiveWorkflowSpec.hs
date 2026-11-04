{-# LANGUAGE DataKinds #-}

-- The real Flow, accepted typed program, native worker and checkpoint owner.
-- Only the key-free provider and the human integration check are fixtures.
module Shikigami.AdaptiveWorkflowSpec (tests) where

import Baikai.Content (AssistantContent (AssistantText, AssistantToolCall), TextContent (..))
import Baikai.Content qualified as Content
import Baikai.Cost qualified as Cost
import Baikai.Evidence qualified as Evidence
import Baikai.Message (AssistantPayload (..))
import Baikai.Model qualified as Model
import Baikai.Options (emptyOptions)
import Baikai.Provider.Registry qualified as Provider
import Baikai.Response (Response (..))
import Baikai.StopReason (StopReason (ToolUse))
import Baikai.Stream (liftCompleteToStream)
import Baikai.Usage qualified as Usage
import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.IORef
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, maybeToList)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as Vector
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow qualified as W
import Keiro.Workflow.Child.Schema qualified as Child
import Keiro.Workflow.Resume (resumeWorkflowsOnce)
import Kiroku.Store.Connection (KirokuStore (..), withStore)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.AdaptiveDelivery.Generated.WorkflowRuntime qualified as Generated
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (CoordinatingSkill, Flow, Skill), IdentityDecl (..), RecordPolicy (Never), defaultDelegationBudget)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Name qualified
import Shikigami.Agent.Principal (AgentIdentity (VerifiedIdentity), mkAgentPrincipal)
import Shikigami.Agent.RunJob (RunRouteKind (AgentWorkflowRoute), runJobWorkflowId)
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.AgentRun.Ledger qualified as Ledger
import Shikigami.AgentRun.RequestKey (parseRequestKey)
import Shikigami.App (AppEffects, AppEnv (..))
import Shikigami.Behavior.Error (TransientBehaviorFailure (..))
import Shikigami.Behavior.Run (newBehaviorEnv)
import Shikigami.Behavior.StubProvider (stubApiProvider, stubModel)
import Shikigami.Coordination.Checkpoint qualified as CP
import Shikigami.Coordination.Proposal qualified as P
import Shikigami.Coordination.Runtime qualified as Runtime
import Shikigami.Coordination.Types
import Shikigami.Coordination.Workflow qualified as Adaptive
import Shikigami.Decision.Contract (DecisionFailure, PreparedDecision (..), parseModelAlias)
import Shikigami.Decision.ModelCatalog (modelBinding, modelCatalog)
import Shikigami.Directory qualified as Directory
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Counter (noAttempts)
import Shikigami.Execution.Driver qualified as Driver
import Shikigami.Execution.Policy.Limits (PolicyNumber (..))
import Shikigami.Execution.Quantity (amountUnits)
import Shikigami.Execution.Request (ExecutionPolicy (..))
import Shikigami.Execution.Resources qualified as R
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript qualified as Replay
import Shikigami.ExecutionTranscriptSpec qualified as Fixture
import Shikigami.Fixture.ExecutionIdentity (fixtureOperationId)
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Objective.Capability qualified as O
import Shikigami.Objective.Command qualified as Command
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Runtime qualified as Objectives
import Shikigami.Objective.Store qualified as Goals
import Shikigami.Objective.Types
import Shikigami.Prelude hiding ((.=))
import Shikigami.Program.Decision.Adaptive (AdaptiveInput (..))
import Shikigami.Repository (repositoryId)
import Shikigami.RouterWorkflowSpec qualified as Router
import Shikigami.Trigger.Enqueue (addressedRunJob, ensureRunQueue)
import Shikigami.WorkerSession.Capability qualified as Workers
import Shikigami.WorkerSession.Input qualified as Input
import Shikigami.WorkerSession.Store qualified as SessionStore
import Shikigami.WorkerSession.Transfer qualified as Transfer
import Shikigami.WorkerSession.Types qualified as WS
import Shikigami.WorkerSession.Workflow qualified as Sessions
import Shikigami.Workflow.Versioning (shikigamiWorkflowResumeOptions)
import Shikigami.Workspace.Catalog qualified as Workspace
import Shikigami.Workspace.Store qualified as Workspace
import Shikigami.Workspace.Types qualified as Workspace
import Shikigami.Workspace.Value (workspaceCoordinate, workspaceLocator)
import Test.Tasty
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "AdaptiveWorkflow"
    [ testCase "native Flow chooses one worker, adapts to a finding and proposes only verified combined acceptance" (scenario fixture False False False False),
      testCase "lost validation acknowledgement reuses the decision and worker before a permitted model escalation" (scenario fixture True False False False),
      testCase "a pinned local coordinator admits and integrates two descendants across a larger live catalog" (scenario fixture False True False False),
      testCase "a pure admitted role does direct work under the coordinator principal without a worker session" (scenario fixture False False True False),
      testCase "an idle worker transfers through retained fence and ownership receipts before the same session resumes" (scenario fixture False False False True)
    ]

scenario :: DatabaseFixture -> Bool -> Bool -> Bool -> Bool -> IO ()
scenario fixture loseAck hierarchical directWork handoff = Fixture.withConfiguredResourceFixture fixture id (Map.insert R.Tokens R.ExplicitlyUnbounded) \original seed _ -> withStore original.connectionSettings \store -> do
  let env = original & #store .~ Just store
  ensureRunQueue store.pool >>= right
  seedState <- Fixture.run env (Execution.inspectExecution seed.executionId) >>= right >>= maybe (fail "missing fixture seed") (pure . (\(state, _, _) -> state))
  _ <- Fixture.run env (Execution.stopExecution seed.identity seed.executionId seedState.revision Replay.StopAsFailure Replay.ExecutionCommandRefused) >>= right
  now <- getCurrentTime
  base <- newBehaviorEnv
  decisions <- newIORef (0 :: Int)
  workerCalls <- newIORef (0 :: Int)
  specialistCalls <- newIORef (0 :: Int)
  localCalls <- newIORef (0 :: Int)
  fences <- newIORef (0 :: Int)
  provisioned <- newIORef False
  lost <- newIORef False
  checkedJourney <- newIORef False
  let principal name = checked (mkAgentPrincipal ("agent_adaptive_" <> name))
      identity name = VerifiedIdentity (principal name)
      rootRole = (Router.successSpecialist "coordinator") & #identity .~ Just (IdentityDecl (declarationCoordinate "agent_adaptive_coordinator")) & #behavior .~ Flow (declarationCoordinate "adaptive-delivery") & #delegates .~ (if hierarchical then [local.name] else [leaf.name] <> [successor.name | handoff]) & #decisionModels .~ [alias] & #memory . #recordPolicy .~ Never
      leaf = (Router.successSpecialist "worker") & #identity .~ Just (IdentityDecl (declarationCoordinate (if directWork then "agent_adaptive_coordinator" else "agent_adaptive_worker"))) & #behavior .~ Skill (declarationCoordinate "../agents/skills/triage-note") & #execution .~ Just (ExecutionPolicy workerAlias (workerAlias : [specialistAlias | loseAck])) & #memory . #recordPolicy .~ Never
      local = (Router.successSpecialist "local") & #identity .~ Just (IdentityDecl (declarationCoordinate "agent_adaptive_local")) & #behavior .~ CoordinatingSkill (declarationCoordinate "../agents/skills/triage-note") & #delegates .~ [leaf.name] & #execution .~ Just (ExecutionPolicy localAlias [localAlias, workerAlias]) & #memory . #recordPolicy .~ Never
      forbidden = (Router.successSpecialist "forbidden") & #identity .~ Just (IdentityDecl (declarationCoordinate "agent_adaptive_forbidden"))
      successor = leaf & #name .~ (checked (Shikigami.Agent.Name.mkAgentName "successor")) & #identity .~ Just (IdentityDecl (declarationCoordinate "agent_adaptive_successor"))
      declarations = [rootRole, leaf] <> [local | hierarchical] <> [successor | handoff]
      workerAlias = checked (parseModelAlias "worker")
      localAlias = checked (parseModelAlias "local")
      specialistAlias = checked (parseModelAlias "specialist")
      alias = checked (parseModelAlias "adaptive")
      binding = checked (modelBinding alias "1" "adaptive-fixture" "1" stubModel emptyOptions Nothing)
      catalog = checked (modelCatalog [binding, checked (modelBinding workerAlias "1" "worker-fixture" "1" stubModel emptyOptions Nothing), checked (modelBinding localAlias "1" "local-fixture" "1" (stubModel & #modelId .~ "stub-local") emptyOptions Nothing), checked (modelBinding specialistAlias "1" "specialist-fixture" "1" (stubModel & #modelId .~ "stub-specialist") emptyOptions Nothing)])
      settings = defaultObjectiveSettings & #enabled .~ ObjectivesEnabled
      ownerCaller = checked (parseCallerId "adaptive-owner")
      owner = O.ObjectiveHost settings (pure (Right (VerifiedCaller ownerCaller))) allowAllActionAuthorizerForTests (\_ _ -> pure (Right ())) (\_ _ -> pure (Left ObjectiveDenied)) (\_ -> pure (Left ObjectiveInvalidEvidence))
      own = checked (parseObjectiveAssignmentId "delivery")
      work = checked (parseObjectiveAssignmentId "implementation")
      descendants = map (checked . parseObjectiveAssignmentId) ["descendant-a", "descendant-b"]
      criterion = checked (parseCriterionKey "combined-journey")
      artifact = checked (parseArtifactRef "combined-fixture-v1")
      checkKey = checked (parseEvidenceKey "combined-journey-passed")
  directory <- Directory.newDirectoryHandle (Directory.staticDirectorySource [Directory.PrincipalRecord (declarationCoordinate ("agent_adaptive_" <> name)) (declarationCoordinate name) Directory.Active | name <- ["coordinator", "worker", "local", "forbidden", "successor"]])
  Directory.refreshDirectory directory >>= (@?= Right ())
  let fencing =
        Transfer.WorkspaceProvider
          ( \intent -> do
              ordinal <- atomicModifyIORef' fences (\n -> (n + 1, n))
              pure (if ordinal == 0 then Transfer.FenceUnresolved else Transfer.FencedAndSettled (Transfer.FenceProof V1 intent.workspace intent.operationId (Transfer.transferFingerprint intent) intent.oldEpoch intent.newEpoch (Input.providerReceiptFor "fixture-fence/1" (toJSON intent))))
          )
          (\_ _ _ _ _ -> pure (Right ()))
      workers = Objectives.coordinationHost env settings directory allowAllActionAuthorizerForTests declarations defaultDelegationBudget (if handoff then Just fencing else Nothing)
      objectives = Objectives.ObjectiveRuntime env settings directory allowAllActionAuthorizerForTests (Just workers)
      owned :: Eff AppEffects (Either ObjectiveError a) -> IO (Either ObjectiveError a)
      owned = Objectives.owned objectives
  created <- owned (O.createObjective owner (fixtureOperationId "native-adaptive-create") Nothing (CreateRequest (checked (parseTitle "finite adaptive fixture")) (checked (parseGoal "deliver a checked combined artifact")) (checked (parseInstructions "Adapt after an early finding, then wait for the actual integration check")) [Criterion criterion (checked (parseCriterionDescription "combined user journey")) HumanVerifiable JourneyRequired] [])) >>= right
  let goal = created.objectiveId
      reference = ObjectiveAssociation goal own
      key = checked (parseRequestKey "native-adaptive")
      job = addressedRunJob now (identity "coordinator") rootRole.name AgentWorkflowRoute (toJSON ("finite fixture" :: Text)) (Ledger.httpRunKey rootRole.name key) & #objective .~ Just reference & #executionRootId .~ seed.selection.rootId
      draft = AssignmentDraft own (checked (parseInstructions "Deliver the finite objective")) [] (identity "coordinator") Pending Nothing Nothing Nothing
  _ <- owned (O.executeCommand owner goal initialRevision (fixtureOperationId "native-adaptive-plan") (Command.SetAssignments [draft])) >>= right
  _ <- owned (O.executeCommand owner goal (advanceRevision initialRevision) (fixtureOperationId "native-adaptive-coordinator") (Command.GrantMember (RecordedAgent (identity "coordinator")) [Coordinator])) >>= right
  _ <- owned (O.executeCommand owner goal (advanceRevisions 2 initialRevision) (fixtureOperationId "native-adaptive-worker") (Command.GrantMember (RecordedAgent (identity "worker")) [Worker])) >>= right
  when handoff do
    _ <- owned (O.executeCommand owner goal (advanceRevisions 3 initialRevision) (fixtureOperationId "native-adaptive-successor") (Command.GrantMember (RecordedAgent (identity "successor")) [Worker])) >>= right
    pure ()
  when hierarchical do
    _ <- owned (O.executeCommand owner goal (advanceRevisions 3 initialRevision) (fixtureOperationId "native-adaptive-local") (Command.GrantMember (RecordedAgent (identity "local")) [Coordinator])) >>= right
    _ <- owned (O.executeCommand owner goal (advanceRevisions 4 initialRevision) (fixtureOperationId "native-adaptive-forbidden") (Command.GrantMember (RecordedAgent (identity "forbidden")) [Worker])) >>= right
    pure ()
  let sessionFor key = do
        identifiers <- Fixture.run env (runTransaction (Tx.statement () (preparable "SELECT session_id FROM shikigami.worker_sessions ORDER BY session_id" E.noParams (D.rowList (D.column (D.nonNullable D.text))))))
        sources <- forM identifiers \identifier -> Fixture.run env (SessionStore.inspectSession (Input.workerSessionId identifier)) >>= right
        maybe (assertFailure "local tool did not create its retained session") pure (find (\(_, binding') -> binding'.objective == Goals.referenceFor goal key) (catMaybes sources))
      localCommand = do
        ordinal <- atomicModifyIORef' localCalls (\n -> (n + 1, n))
        current <- owned (O.readObjective owner goal) >>= right
        let findChild key = pure (Just (Workers.FindWorker (Input.workerCoordinate (objectiveAssignmentIdText key))))
            sendChild key = do
              (state, _) <- sessionFor key
              assignment <- maybe (assertFailure "descendant missing") pure (find ((== key) . (.definition.assignmentId)) current.assignments)
              pure (Just (Workers.SendWorker state.sessionId state.revision state.epoch (Workers.WorkerInstruction (checked (Input.parseInstructionText "Execute this bounded descendant and retain its finding")) current.revision assignment.revision current.criteriaRevision Nothing)))
        command <- case ordinal of
          0 -> findChild (head descendants)
          1 -> sendChild (head descendants)
          2 -> findChild (last descendants)
          3 -> sendChild (last descendants)
          _ -> do
            states <- traverse sessionFor descendants
            case find (\(state, _) -> state.phase == WS.Idle && state.consumedCursor < state.eventCursor) states of
              Just (state, _) -> pure (Just (Workers.IntegrateWorkerEvents state.sessionId))
              Nothing | all (\key -> any ((== key) . (.assignmentId)) current.reportedResults) descendants -> pure Nothing
              _ -> let (state, _) = head states in pure (Just (Workers.ReadWorkerEvents state.sessionId initialRevision (checked (Input.parseSessionLimit 100))))
        pure (ordinal, command)
      complete model context options = do
        response <- Provider.complete stubApiProvider model context options
        output <-
          if "proposalJson" `Text.isInfixOf` Text.pack (show context)
            then do
              modifyIORef' decisions (+ 1)
              journal <- Fixture.run env (W.loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId job) 0)
              admission <- case Map.lookup "adaptive-admission" journal of
                Just raw | Aeson.Success (Right value) <- Aeson.fromJSON @(Either ObjectiveError Admission) raw -> pure value
                _ -> assertFailure "missing protected adaptive admission"
              generation <- Fixture.run env (W.currentGeneration Generated.workflowName admission.run.runId)
              steps <- Fixture.run env (W.loadStepIndex Generated.workflowName admission.run.runId generation)
              prepared <- case Map.lookup "decision-prepare-adapt" steps of
                Just raw | Aeson.Success (Right value) <- Aeson.fromJSON @(Either DecisionFailure PreparedDecision) raw -> pure value
                _ -> assertFailure "typed program has no prepared input"
              input <- case Aeson.fromJSON @AdaptiveInput prepared.input of Aeson.Success value -> pure value; _ -> assertFailure "typed input codec"
              fields <- case Aeson.eitherDecodeStrict (Text.encodeUtf8 input.checkpointJson) of Right (Aeson.Object value) -> pure value; _ -> assertFailure "checkpoint input codec"
              pinned <- case Aeson.fromJSON @CP.Checkpoint (fromMaybe Aeson.Null (KeyMap.lookup "checkpoint" fields)) of Aeson.Success value -> pure value; _ -> assertFailure "checkpoint codec"
              let current = pinned.objective
                  operation = Runtime.operationKey "decision" (toJSON (admission.run, generation, current.revision))
                  worker = find ((== work) . (.definition.assignmentId)) current.assignments
                  instruction value text = Workers.WorkerInstruction (checked (Input.parseInstructionText text)) current.revision value.revision current.criteriaRevision Nothing
                  reported = find ((== work) . (.assignmentId)) current.reportedResults
                  initialPlacement key role parent = P.Placement (AssignmentDraft key (checked (parseInstructions "Execute the bounded assignment")) [] (identity (if directWork then "coordinator" else role)) Pending Nothing (Just admission.organization.rootId) (Just admission.organization.cutoff)) (if role == "local" then local.name else leaf.name) parent
                  changes
                    | any ((== checkKey) . (.input.key)) current.evidence = [P.ProposeCompletion (P.IntegratedAcceptance current.revision current.instructionsRevision current.criteriaRevision [artifact] [checkKey] [])]
                    | isNothing worker = [P.CreateAssignment (initialPlacement work (if hierarchical then "local" else "worker") Nothing)] <> [P.CreateAssignment (initialPlacement key "worker" (Just work)) | key <- descendants, hierarchical]
                    | handoff, Just value <- worker, value.definition.owner == identity "worker", Just _ <- reported, Just workspace <- lookup work pinned.workspaces = [P.TransferAssignment work successor.name workspace]
                    | handoff, Just value <- worker, value.definition.owner == identity "worker", Just _ <- reported = [P.AwaitAssignments [own]]
                    | Just value <- worker, Just observed <- reported, revisionNumber observed.receipt.cursor <= 3 = if loseAck then [P.EscalateModel work specialistAlias] else [P.FollowUpContext work (instruction value "The early finding needs a bounded correction in the same session")]
                    | otherwise = [P.AwaitAssignments [own]]
                  proposal = P.Proposal V1 goal current.revision current.instructionsRevision current.criteriaRevision operation (map (.input.key) current.evidence) (checked (parseCriterionDescription "Reflect on retained findings")) Nothing (checked (parseCriterionDescription "Use one bounded worker and require a combined check")) (checked (parseEvidenceKey "next-finding")) changes
              pure (Text.decodeUtf8 (Lazy.toStrict (Aeson.encode (Aeson.object ["proposalJson" .= Text.decodeUtf8 (Lazy.toStrict (Aeson.encode proposal))]))))
            else do
              unless (hierarchical && Model.modelId model == "stub-local") (modifyIORef' workerCalls (+ 1))
              when (Model.modelId model == "stub-specialist") (modifyIORef' specialistCalls (+ 1))
              pure "fixture: early finding / correction retained"
        tool <-
          if hierarchical && Model.modelId model == "stub-local"
            then do
              (ordinal, command) <- localCommand
              pure (fmap (\value -> Content.ToolCall ("local-" <> Text.pack (show ordinal)) "workers" (toJSON value)) command)
            else pure Nothing
        let usage = Usage.zeroUsage & #availability .~ Just (Usage.UsageAvailability Set.empty False Set.empty) & #cost . #basis .~ Cost.providerReportedBasis
            message = case tool of
              Nothing -> response & #message . #content .~ Vector.singleton (AssistantText (TextContent output))
              Just invocation -> response & #message . #stopReason .~ ToolUse & #message . #content .~ Vector.singleton (AssistantToolCall invocation)
        -- This in-process provider really performs zero billed transport work.
        let envelope = Aeson.object ["content" .= message.message.content, "stop_reason" .= message.message.stopReason, "usage" .= Evidence.usageEnvelope usage]
        pure (message & #evidence %~ fmap (\value -> value & #usage .~ Evidence.Observed usage & #responseCommitment .~ Evidence.Observed (Evidence.commitmentDigest envelope)))
      provider = stubApiProvider & #complete .~ complete & #stream .~ liftCompleteToStream complete
  registry <- Provider.newProviderRegistryFrom [provider]
  let behavior = base & #providerRegistry .~ Just registry
      routing = Routing.RoutingRuntime (\_ -> pure Router.catalog) (\_ _ _ -> error "unused routing")
      services = Decision.defaultDecisionServices catalog & #providers .~ [provider]
      dependencies = (Router.routerDeps env behavior routing declarations) & #directory .~ directory & #objectives .~ Just objectives & #coordination .~ Just workers & #decisions .~ services & #deliveryPool .~ Just store.pool & #harness . #maxModelTurns .~ checked (parsePolicyNumber (if hierarchical then 64 else 8)) & #hooks . #afterStepBody .~ (\name -> when (loseAck && name == W.StepName "adaptive-validation") do first <- atomicModifyIORef' lost (\old -> (True, not old)); when first (throwIO (TransientBehaviorFailure "lost adaptive decision acknowledgement")))
      liveDeclarations = [rootRole, leaf, local & #delegates .~ [leaf.name, forbidden.name], forbidden]
      liveHost = Objectives.coordinationHost env settings directory allowAllActionAuthorizerForTests liveDeclarations defaultDelegationBudget Nothing
      active = if hierarchical then dependencies & #agents .~ liveDeclarations & #coordination .~ Just liveHost & #harness . #maxModelTurns .~ checked (parsePolicyNumber 64) else dependencies
      workflows = Agent.agentRunRegistry active `Map.union` Driver.executionRegistry (Agent.executionRuntime active) `Map.union` Adaptive.registry (Agent.adaptiveRuntime active) `Map.union` Sessions.sessionRegistry (Agent.workerSessionRuntime active)
      pump 0 = do
        current <- owned (O.readObjective owner goal) >>= right
        journal <- Fixture.run env (W.loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId job) 0)
        forM_ (Map.lookup "adaptive-admission" journal) \raw -> case Aeson.fromJSON @(Either ObjectiveError Admission) raw of
          Aeson.Success (Right admission) -> do
            generation <- Fixture.run env (W.currentGeneration Generated.workflowName admission.run.runId)
            entries <- Fixture.run env (W.loadStepIndex Generated.workflowName admission.run.runId generation)
            assertFailure (show (generation, [(name, value) | (name, value) <- Map.toList entries, name `elem` ["adaptive-validation", "__workflow_completed__"]], [(value.definition.assignmentId, value.definition.state) | value <- current.assignments], length current.reportedResults))
          _ -> pure ()
        assertFailure "adaptive Flow exceeded its finite fixture"
      pump remaining = do
        _ <- Fixture.run env (resumeWorkflowsOnce (shikigamiWorkflowResumeOptions env 30) workflows)
        executions <- Fixture.run env (runTransaction (Tx.statement () (preparable "SELECT execution_id FROM shikigami.executions ORDER BY execution_id" E.noParams (D.rowList (D.column (D.nonNullable D.text))))))
        forM_ executions \raw -> do
          retained <- Fixture.run env (Execution.inspectExecution (Replay.executionIdentity raw)) >>= right
          forM_ retained \(state, binding', _) -> forM_ state.activeOperation \operation -> do
            attempts <- Fixture.run env (Execution.inspectOperationAttempts operation) >>= right
            forM_ (filter Attempt.logicalAttempt attempts) \attempt -> do
              _ <- Agent.executeAcceptedOperation active binding'.identity (Attempt.JobReference V1 state.executionId operation attempt.request.attemptId) >>= right
              pure ()
        current <- owned (O.readObjective owner goal) >>= right
        preparedWorkspace <- readIORef provisioned
        when (handoff && not preparedWorkspace && not (null current.reportedResults)) do
          let result = head current.reportedResults
              native = result.receipt
              revision = workspaceCoordinate (Text.replicate 40 "a")
              repository = repositoryId "mori://fixture/adaptive-delivery"
              policies = checked (Workspace.mkWorkspaceCatalog [Workspace.RepositoryPolicy repository (workspaceLocator "/tmp/shikigami-adaptive-source-fixture") [revision] revision (workspaceCoordinate "fixture-policy")])
              resolved = checked (Workspace.resolveRepository policies repository Nothing)
          access <- Fixture.run env (SessionStore.authorizeSession native.sessionId (identity "coordinator") (pure (Right ()))) >>= right
          message <- Fixture.run env (SessionStore.readAssignment access native.assignmentId) >>= right
          child <- maybe (assertFailure "fixture child source missing") pure message.childWorkflowId
          let request = Workspace.WorkspaceRequest child (Just (native.sessionId, native.assignmentId)) (fromMaybe (error "root") seed.selection.rootId) (identity "coordinator") (identity "worker") initialRevision
          (binding', _) <- Fixture.run env (runTransaction (Workspace.reserveWorkspaceTx "/tmp/shikigami-adaptive-workspace-fixture" request resolved)) >>= right
          -- This is a protocol fixture, not filesystem/containment qualification.
          Fixture.run env (runTransaction (Workspace.markWorkspaceReadyTx binding')) >>= (@?= Right ())
          _ <- owned (O.executeCommand owner goal current.revision (fixtureOperationId "workspace-evidence-ready") (Command.SetNextAction [checked (parseNextAction "An owner-verified transferable workspace is now available")])) >>= right
          writeIORef provisioned True
        forM_ current.reportedResults \reported -> when (reported.receipt.disposition /= WS.AssignmentSucceeded) do
          access <- Fixture.run env (SessionStore.authorizeSession reported.receipt.sessionId (identity "coordinator") (pure (Right ()))) >>= right
          message <- Fixture.run env (SessionStore.readAssignment access reported.receipt.assignmentId) >>= right
          details <- forM (maybeToList message.childWorkflowId) \native -> Fixture.run env (Child.lookupChild native.unWorkflowId Agent.agentRunWorkflowName.unWorkflowName)
          assertFailure (show (reported.receipt.disposition, map (fmap (.result)) details))
        provided <- readIORef checkedJourney
        when (not provided && (if directWork then maybe False ((== Done) . (.definition.state)) (find ((== work) . (.definition.assignmentId)) current.assignments) else any (\reported -> reported.assignmentId == work && revisionNumber reported.receipt.cursor > 3) current.reportedResults) && all (\key -> any ((== key) . (.assignmentId)) current.reportedResults) (if hierarchical then descendants else [])) do
          forM_ (work : [key | key <- descendants, hierarchical]) \key -> do
            latest <- owned (O.readObjective owner goal) >>= right
            unless directWork do
              _ <- owned (O.executeCommand owner goal latest.revision (Runtime.operationKey "integrator-accepts-worker-finding" (toJSON key)) (Command.RecordProgress key Done [] [])) >>= right
              pure ()
          refreshed <- owned (O.readObjective owner goal) >>= right
          _ <- owned (O.executeCommand owner goal refreshed.revision (fixtureOperationId "actual-combined-check") (Command.RecordEvidence work (Attestation checkKey criterion artifact (checked (parseAttestationStatement "The fixture's combined user journey passed")) JourneyObserved))) >>= right
          writeIORef checkedJourney True
        latest <- owned (O.readObjective owner goal) >>= right
        if isJust latest.proposed then pure latest else threadDelay 20000 >> pump (remaining - 1)
  _ <- Ledger.acceptObjectiveRunRequest settings store.pool job key (Ledger.callerAttribution "adaptive-owner") >>= right
  Agent.runAgentRunWorkflow dependencies job >>= (@?= Right W.Suspended)
  completed <- pump (400 :: Int)
  completed.status @?= Open
  length completed.assignments @?= if hierarchical then 4 else 2
  length completed.reportedResults @?= if directWork then 0 else if hierarchical then 3 else 1
  readIORef workerCalls >>= (@?= if directWork then 1 else 2)
  readIORef specialistCalls >>= (@?= if loseAck then 1 else 0)
  calls <- readIORef decisions
  assertBool ("bounded reflection count: " <> show calls) (calls >= (if directWork then 2 else 4) && calls <= (if hierarchical || handoff then 12 else 8))
  forM_ completed.proposed \(proposal, proposer) -> do
    proposal.artifacts @?= [artifact]
    proposal.checks @?= [checkKey]
    proposer @?= RecordedAgent (identity "coordinator")
  actualRoot <- Fixture.run env (Roots.inspectRoot (fromMaybe (error "fixture root") seed.selection.rootId)) >>= right
  actualWorkers <- readIORef workerCalls
  actualLocal <- readIORef localCalls
  actualRoot.active @?= noAttempts
  actualRoot.unknown @?= noAttempts
  fmap amountUnits (Map.lookup R.ModelAttempts actualRoot.usage.settled) @?= Just (toInteger (calls + actualWorkers + actualLocal))
  _ <- owned (O.executeCommand owner goal completed.revision (fixtureOperationId "owner-accepts-exact-artifact") Command.AcceptCompletion) >>= right
  accepted <- owned (O.readObjective owner goal) >>= right
  accepted.status @?= Completed
  -- There is exactly one native worker despite both reflection and a lost ack.
  sessions <- Fixture.run env (runTransaction (Tx.statement () (preparable "SELECT count(*) FROM shikigami.worker_sessions" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))))
  sessions @?= if directWork then 0 else if hierarchical then 3 else 1
  when hierarchical do
    childJobs <- Fixture.run env (runTransaction (Tx.statement () (preparable "SELECT source_id FROM shikigami.objective_associations WHERE kind='run'" E.noParams (D.rowList (D.column (D.nonNullable D.text))))))
    forM_ childJobs \identifier -> do
      steps <- Fixture.run env (W.loadStepIndex Agent.agentRunWorkflowName (W.WorkflowId identifier) 0)
      forM_ (Map.lookup "lookup-agent" steps) \raw -> case Aeson.fromJSON @(Maybe AgentDecl) raw of
        Aeson.Success (Just declaration) | declaration.name == local.name -> declaration.delegates @?= [leaf.name]
        _ -> pure ()
    readIORef localCalls >>= assertBool "local model exercised its own descendant tools" . (>= 7)
  when handoff do
    assignment <- maybe (assertFailure "transferred assignment missing") pure (find ((== work) . (.definition.assignmentId)) completed.assignments)
    assignment.definition.owner @?= identity "successor"
    assignment.ownerEpoch @?= advanceRevision initialRevision
    readIORef fences >>= assertBool "the same fence was repaired and verified by the owner" . (>= 3)
  when loseAck (readIORef lost >>= (@?= True))

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

checked :: (Show e) => Either e a -> a
checked = either (error . show) id
