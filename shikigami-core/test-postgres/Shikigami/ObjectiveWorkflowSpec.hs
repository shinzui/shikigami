{-# LANGUAGE DataKinds #-}

-- Real execution/model-tool consumers of the objective owner. The inherited
-- fixture supplies only an admitted resource envelope and immutable model data;
-- objective tools, operations, attempts, receipts and progress are production.
module Shikigami.ObjectiveWorkflowSpec (tests, oldAgentReplay, oldConversationReplay) where

import Baikai.Content qualified as Content
import Baikai.Context qualified as Context
import Baikai.Provider.Registry qualified as Provider
import Baikai.StopReason (StopReason (ToolUse))
import Baikai.Stream (liftCompleteToStream)
import Control.Exception (SomeException, throwIO, try)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft, isRight)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as Vector
import Effectful.Dispatch.Static (unsafeEff_)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (StepRecorded), WorkflowOutcome (..), loadStepIndex, prepareJournalAppend, runWorkflow)
import Keiro.Workflow.Resume (resumeWorkflowsOnce)
import Kiroku.Store.Connection (KirokuStore (..), withStore)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (Flow, Skill), IdentityDecl (..), RecordPolicy (Never), defaultDelegationBudget)
import Shikigami.Agent.DeclarationValue (declarationCoordinate, declarationCoordinateText)
import Shikigami.Agent.Principal (AgentIdentity (VerifiedIdentity), mkAgentPrincipal)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.Run.Key (parseRunKey)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), runJobWorkflowId)
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.AgentRun.Ledger qualified as Ledger
import Shikigami.AgentRun.RequestKey (parseRequestKey)
import Shikigami.App (AppEnv (..))
import Shikigami.Behavior.Error (TransientBehaviorFailure (..))
import Shikigami.Behavior.Run (BehaviorEnv (..), newBehaviorEnv)
import Shikigami.Behavior.StubProvider (stubApiProvider)
import Shikigami.Capability.Provider (emptyCapabilityProviderRegistry)
import Shikigami.Directory qualified as Directory
import Shikigami.Duration (parseDuration)
import Shikigami.Execution.AssignmentKey (assignmentIdFor)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Driver qualified as Driver
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Identity (parseOperationId)
import Shikigami.Execution.Progress (noPendingReceipts)
import Shikigami.Execution.Request (ExecutionContext (..))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.Runner qualified as Runner
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.SelectionRuntime (SelectionRuntime (..))
import Shikigami.Execution.SelectionRuntime qualified as SelectionRuntime
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Tools qualified as Native
import Shikigami.Execution.Transcript qualified as Replay
import Shikigami.ExecutionDriver.Generated.WorkflowRuntime qualified as DriverGenerated
import Shikigami.ExecutionSelectionWorkflowSpec qualified as SelectionFixture
import Shikigami.ExecutionTranscriptSpec qualified as Fixture
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Integration.Danwa (AddressedMessage (..))
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Objective.Capability qualified as Goal
import Shikigami.Objective.Command qualified as Command
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Runtime qualified as Objectives
import Shikigami.Objective.Scope qualified as Scope
import Shikigami.Objective.Tools qualified as Tools
import Shikigami.Objective.Types qualified as O
import Shikigami.Prelude hiding ((.=))
import Shikigami.RouterWorkflowSpec qualified as RouterFixture
import Shikigami.Sink.Config (DanwaConfig (..))
import Shikigami.Sink.GrantStore (GrantSource (StaticGrants))
import Shikigami.Sink.Permission (SinkKind (SDanwaConversation))
import Shikigami.Trigger.Enqueue (addressedRunJob, ensureRunQueue)
import Shikigami.Workflow.Versioning (shikigamiWorkflowResumeOptions)
import Shikumi.Tool (SomeTool (..), runErasedOutput, someToolDescription, someToolName, someToolSchema)
import Shikumi.Tool.Output qualified as ToolOutput
import Test.Tasty
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "ObjectiveWorkflow"
    [ testCase "an unassociated native model tool creates, plans, records progress and reads through one frozen binding" (nativeCreation fixture False),
      testCase "lost creation acknowledgement recovers the same receipt after creator policy revocation and continues the original binding" (nativeCreation fixture True),
      testCase "integrated acceptance waits for a real unacknowledged tool receipt even before checkpoint projection" (nativeScenario fixture False True),
      testCase "a registered Flow creates its first objective, records progress and reads through its admitted scope" (flowCreation fixture False),
      testCase "a registered Flow recovers creation after its journal append fails and creator policy is revoked" (flowCreation fixture True),
      testCase "a durable Skill admits first-objective creation before the actual model and records progress" (skillCreation fixture),
      testCase "a Skill without a creation grant cannot manufacture an objectives tool call" (skillScenario fixture DeniedCreator),
      testCase "unavailable objective authority refuses a creator before model or execution dispatch" (skillScenario fixture UnavailableOwner),
      testCase "revoking membership after Skill admission refuses the model write through its original binding" (associatedSkillScenario fixture True),
      testCase "a model cannot substitute another accessible objective for its accepted association" (associatedSkillScenario fixture False),
      testCase "a recorded conversation creates, recovers a lost reply and explicitly binds a later turn" (conversationCreation fixture)
    ]

conversationCreation :: DatabaseFixture -> IO ()
conversationCreation fixture = Fixture.withConfiguredResourceFixture fixture id (Map.insert Resources.Tokens Resources.ExplicitlyUnbounded) \env seed _ -> withStore env.connectionSettings \store -> do
  ensureRunQueue store.pool >>= right
  now <- getCurrentTime
  base <- newBehaviorEnv
  calls <- newIORef (0 :: Int)
  laterTarget <- newIORef Nothing
  readReplies <- newIORef ([] :: [Aeson.Value])
  lost <- newIORef False
  let principal = checked mkAgentPrincipal "agent_objectives_conversation"
      actor = VerifiedIdentity principal
      declaration = (RouterFixture.successSpecialist "worker") & #identity .~ Just (IdentityDecl (declarationCoordinate "agent_objectives_conversation")) & #behavior .~ Skill (declarationCoordinate "../agents/skills/triage-note") & #memory . #recordPolicy .~ Never
      settings = O.defaultObjectiveSettings & #enabled .~ O.ObjectivesEnabled & #agentCreation .~ [principal]
      complete model context options = do
        ordinal <- atomicModifyIORef' calls (\n -> (n + 1, n))
        response <- Provider.complete stubApiProvider model context options
        request <- case ordinal of
          0 -> pure (Just createInput)
          1 -> Just . planInput <$> goalFromContext context
          2 -> Just . progressInput <$> goalFromContext context
          3 -> Just . inspectInput <$> goalFromContext context
          5 -> fmap inspectInput <$> readIORef laterTarget
          _ -> pure Nothing
        pure case request of
          Nothing -> response
          Just arguments -> response & #message . #stopReason .~ ToolUse & #message . #content .~ Vector.singleton (Content.AssistantToolCall (Content.ToolCall ("conversation-objectives-" <> Text.pack (show ordinal)) "objectives" arguments))
      provider = stubApiProvider & #complete .~ complete & #stream .~ liftCompleteToStream complete
      message number = AddressedMessage (declarationCoordinate "objective-conversation") (declarationCoordinate ("message-" <> Text.pack (show number))) Nothing (declarationCoordinate "human") "Continue the work" (declarationCoordinate "participant") (declarationCoordinate ("envelope-" <> Text.pack (show number))) (declarationCoordinate "human") now
  registry <- Provider.newProviderRegistryFrom [provider]
  directory <- Directory.newDirectoryHandle (Directory.staticDirectorySource [Directory.PrincipalRecord (declarationCoordinate "agent_objectives_conversation") (declarationCoordinate "worker") Directory.Active])
  Directory.refreshDirectory directory >>= (@?= Right ())
  let runtime = Objectives.ObjectiveRuntime env settings directory allowAllActionAuthorizerForTests Nothing
      configured = base & #providerRegistry .~ Just registry
      dependencies = (RouterFixture.routerDeps env configured (Routing.RoutingRuntime (\_ -> pure RouterFixture.catalog) (\_ _ _ -> error "unused routing")) [declaration]) & #directory .~ directory & #objectives .~ Just runtime & #decisions . #providers .~ [provider] & #deliveryPool .~ Just store.pool
      conversation =
        Conversation.ConversationEnv
          { appEnv = env,
            behaviorEnv = configured,
            decisions = dependencies.decisions,
            objectives = Just runtime,
            deliveryPool = Just store.pool,
            resolveRunProfile = dependencies.resolveRunProfile,
            runTimeout = dependencies.runTimeout,
            harness = dependencies.harness,
            idleTimeout = checked parseDuration 1800,
            danwa = DanwaConfig "http://localhost:1" (declarationCoordinate "participant"),
            agents = [declaration],
            grants = StaticGrants (Map.singleton actor (Set.singleton SDanwaConversation)),
            directory
          }
      firstMessage = message (1 :: Int)
      secondMessage = message (2 :: Int)
      workflowId = Conversation.conversationWorkflowId 0 firstMessage
      execution msg = Replay.executionIdFor (SelectionRuntime.conversationAssignmentIdFor workflowId.unWorkflowId (declarationCoordinateText msg.messageId))
      original = Agent.executionRuntime dependencies
      executor = original {Executor.withTools = \snapshot context requested use -> case original of Executor.ExecutionRuntime {withTools = actual} -> actual snapshot context requested (use . map wrap)}
      wrap bound =
        bound
          { Executor.tool = DynTool (someToolName bound.tool) (someToolDescription bound.tool) (someToolSchema bound.tool) \arguments -> do
              output <- runErasedOutput bound.tool arguments
              when (tag arguments == Just "InspectObjective") case output of
                Right rich -> unsafeEff_ (modifyIORef' readReplies (<> [fromMaybe Aeson.Null rich.structuredContent]))
                _ -> pure ()
              when (tag arguments == Just "CreateObjective") do
                first <- unsafeEff_ (atomicModifyIORef' lost (\old -> (True, not old)))
                when first (unsafeEff_ (throwIO (TransientBehaviorFailure "lost conversation tool acknowledgement after objective commit")))
              pure output
          }
  Conversation.submitConversationTurnWithExecution conversation declaration actor (Just (ExecutionContext seed.selection.rootId Nothing Nothing)) firstMessage >>= (@?= Right Conversation.ConversationAccepted)
  completed <- SelectionFixture.driveExecutionChild env executor (execution firstMessage) 80
  assertBool (show completed) (completed.phase == Replay.Succeeded)
  first <- Conversation.runConversationTurnWithExecution conversation declaration actor Nothing firstMessage >>= right
  goals <- Objectives.owned runtime (Goal.listObjectives (Objectives.hostFor runtime actor) Nothing 20) >>= right
  length goals @?= 1
  let current = head goals
      goal = current.objectiveId
  current.revision @?= checked O.parseRevision 2
  conversationRef <- right (O.parseConversationRef "objective-conversation")
  _ <- Objectives.owned runtime (Goal.executeCommand (Objectives.hostFor runtime actor) goal current.revision (checked parseOperationId "bind-later-conversation") (Command.BindConversation conversationRef)) >>= right
  atomicModifyIORef' laterTarget (const (Just goal, ()))
  let laterRuntime = runtime & #settings . #agentCreation .~ []
      laterConversation = conversation & #objectives .~ Just laterRuntime
      laterDependencies = dependencies & #objectives .~ Just laterRuntime
      laterExecutorBase = Agent.executionRuntime laterDependencies
      laterExecutor = laterExecutorBase {Executor.withTools = \snapshot context requested use -> case laterExecutorBase of Executor.ExecutionRuntime {withTools = actual} -> actual snapshot context requested (use . map wrap)}
  Conversation.submitConversationTurnWithExecution laterConversation declaration actor Nothing secondMessage >>= (@?= Right Conversation.ConversationAccepted)
  later <- SelectionFixture.driveExecutionChild env laterExecutor (execution secondMessage) 40
  assertBool (show later) (later.phase == Replay.Succeeded)
  second <- Conversation.runConversationTurnWithExecution laterConversation declaration actor Nothing secondMessage >>= right
  first.sessionId @?= second.sessionId
  replies <- readIORef readReplies
  length replies @?= 2
  assertBool "later conversation reads the current authoritative revision" (containsRevision 3 (last replies))

containsRevision :: Integer -> Aeson.Value -> Bool
containsRevision expected = \case
  Aeson.Object fields -> KeyMap.lookup "revision" fields == Just (toJSON expected) || any (containsRevision expected) (KeyMap.elems fields)
  Aeson.Array values -> any (containsRevision expected) values
  Aeson.String raw -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 raw) of Right value -> containsRevision expected value; Left _ -> False
  _ -> False

oldAgentReplay :: DatabaseFixture -> IO ()
oldAgentReplay fixture = oldShapeReplay fixture False

oldConversationReplay :: DatabaseFixture -> IO ()
oldConversationReplay fixture = oldShapeReplay fixture True

-- The public native journal owner writes only a pre-objective ingest record.
-- There is no patch-set record. New code must complete the original path while
-- every attempt to consult the objective runtime fails the test immediately.
oldShapeReplay :: DatabaseFixture -> Bool -> IO ()
oldShapeReplay fixture conversationCase = Fixture.withFixture fixture \env _ _ -> withStore env.connectionSettings \store -> do
  ensureRunQueue store.pool >>= right
  now <- getCurrentTime
  base <- newBehaviorEnv
  let actor = VerifiedIdentity (checked mkAgentPrincipal "agent_objectives_old_shape")
      declaration = (RouterFixture.successSpecialist "worker") & #identity .~ Just (IdentityDecl (declarationCoordinate "agent_objectives_old_shape")) & #behavior .~ Skill (declarationCoordinate "../agents/skills/triage-note") & #memory . #recordPolicy .~ Never
      job = addressedRunJob now actor declaration.name AgentWorkflowRoute (Aeson.object []) (checked parseRunKey "old-shape-objectives")
      message = AddressedMessage (declarationCoordinate "old-objective-conversation") (declarationCoordinate "old-message") Nothing (declarationCoordinate "human") "Original turn" (declarationCoordinate "participant") (declarationCoordinate "envelope") (declarationCoordinate "human") now
      run = if conversationCase then Conversation.conversationWorkflowId 0 message else runJobWorkflowId job
      name = if conversationCase then Conversation.conversationWorkflowName else Agent.agentRunWorkflowName
      input = if conversationCase then Aeson.object ["agentName" .= declaration.name, "identity" .= actor, "initialMessage" .= message] else toJSON job
      label = if conversationCase then "ingest-start" else "ingest-job"
      assignment = if conversationCase then SelectionRuntime.conversationAssignmentIdFor run.unWorkflowId "old-message" else assignmentIdFor run.unWorkflowId
      execution = Replay.executionIdFor assignment
  directory <- Directory.newDirectoryHandle (Directory.staticDirectorySource [Directory.PrincipalRecord (declarationCoordinate "agent_objectives_old_shape") (declarationCoordinate "worker") Directory.Active])
  Directory.refreshDirectory directory >>= (@?= Right ())
  let dependencies = (RouterFixture.routerDeps env base (Routing.RoutingRuntime (\_ -> pure RouterFixture.catalog) (\_ _ _ -> error "unused routing")) [declaration]) & #directory .~ directory & #objectives .~ Just (error "old agent branch consulted objective policy") & #deliveryPool .~ Just store.pool
      conversation =
        Conversation.ConversationEnv
          { appEnv = env,
            behaviorEnv = base,
            decisions = dependencies.decisions,
            objectives = Just (error "old conversation branch consulted objective policy"),
            deliveryPool = Just store.pool,
            resolveRunProfile = dependencies.resolveRunProfile,
            runTimeout = dependencies.runTimeout,
            harness = dependencies.harness,
            idleTimeout = checked parseDuration 1800,
            danwa = DanwaConfig "http://localhost:1" (declarationCoordinate "participant"),
            agents = [declaration],
            grants = StaticGrants (Map.singleton actor (Set.singleton SDanwaConversation)),
            directory
          }
  Fixture.run env do
    append <- prepareJournalAppend name run 0 (StepRecorded label input now)
    void (runTransaction append)
  if conversationCase
    then void (Fixture.run env (resumeWorkflowsOnce (shikigamiWorkflowResumeOptions env 300) (Conversation.conversationRegistry conversation)))
    else Agent.runAgentRunWorkflow dependencies job >>= (@?= Right Suspended)
  completed <- SelectionFixture.driveExecutionChild env (Agent.executionRuntime dependencies) execution 30
  assertBool (show completed) (completed.phase == Replay.Succeeded)
  if conversationCase
    then void (Conversation.runConversationTurnWithExecution conversation declaration actor Nothing message >>= right)
    else do
      finished <- Agent.runAgentRunWorkflow dependencies job
      assertBool (show finished) (case finished of Right (Completed (Right _)) -> True; _ -> False)
  index <- Fixture.run env (loadStepIndex name run 0)
  let guard = if conversationCase then "patch:shikigami-conversation-objective-tracking-v1" else "patch:shikigami-objective-tracking-v1"
  Map.lookup guard index @?= Just (Aeson.Bool False)
  assertBool "old branches never journal new policy" (Map.notMember "objectives-policy" index && Map.notMember "objectives-inline-policy" index)
  access <- Fixture.run env (Execution.authorizeReplay execution actor (Directory.identityLifecycleAdmission directory actor)) >>= right
  (snapshot, _) <- Fixture.run env (Execution.loadExecution access) >>= right
  snapshot.objectiveScope @?= Nothing
  assertBool "old accepted menu has no objective tools" (all ((/= Replay.executionCoordinate "objectives") . (.name)) snapshot.toolBindings)

associatedSkillScenario :: DatabaseFixture -> Bool -> IO ()
associatedSkillScenario fixture revoke = Fixture.withFixture fixture \env _ _ -> withStore env.connectionSettings \store -> do
  ensureRunQueue store.pool >>= right
  now <- getCurrentTime
  base <- newBehaviorEnv
  let actor = VerifiedIdentity (checked mkAgentPrincipal "agent_objective_member")
      declaration = (RouterFixture.successSpecialist "worker") & #identity .~ Just (IdentityDecl (declarationCoordinate "agent_objective_member")) & #behavior .~ Skill (declarationCoordinate "../agents/skills/triage-note") & #memory . #recordPolicy .~ Never
      settings = O.defaultObjectiveSettings & #enabled .~ O.ObjectivesEnabled
      caller = checked O.parseCallerId "objective-source-owner"
      assignmentKey = checked O.parseObjectiveAssignmentId "own-work"
      draft = O.AssignmentDraft assignmentKey (checked O.parseInstructions "Work") [] actor O.Pending Nothing Nothing Nothing
      request = case createInput of Aeson.Object fields -> case Aeson.fromJSON (fromMaybe Aeson.Null (KeyMap.lookup "request" fields)) of Aeson.Success value -> value; Aeson.Error err -> error err; _ -> error "invalid fixture"
  directory <- Directory.newDirectoryHandle (Directory.staticDirectorySource [Directory.PrincipalRecord (declarationCoordinate "agent_objective_member") (declarationCoordinate "worker") Directory.Active])
  Directory.refreshDirectory directory >>= (@?= Right ())
  let coordination = Objectives.coordinationHost env settings directory allowAllActionAuthorizerForTests [declaration] defaultDelegationBudget Nothing
      runtime = Objectives.ObjectiveRuntime env settings directory allowAllActionAuthorizerForTests (Just coordination)
      owner = (Objectives.hostFor runtime actor) & #authenticate .~ pure (Right (O.VerifiedCaller caller))
      create key = do
        created <- Objectives.owned runtime (Goal.createObjective owner (checked parseOperationId (key <> "-create")) Nothing request) >>= right
        _ <- Objectives.owned runtime (Goal.executeCommand owner created.objectiveId (checked O.parseRevision 0) (checked parseOperationId (key <> "-assign")) (Command.SetAssignments [draft])) >>= right
        _ <- Objectives.owned runtime (Goal.executeCommand owner created.objectiveId (checked O.parseRevision 1) (checked parseOperationId (key <> "-grant")) (Command.GrantMember (O.RecordedAgent actor) [O.Coordinator, O.Reader])) >>= right
        pure created.objectiveId
  originalGoal <- create "original"
  target <- if revoke then pure originalGoal else create "unrelated"
  calls <- newIORef (0 :: Int)
  let complete model context options = do
        ordinal <- atomicModifyIORef' calls (\n -> (n + 1, n))
        response <- Provider.complete stubApiProvider model context options
        if ordinal == 0
          then pure (response & #message . #stopReason .~ ToolUse & #message . #content .~ Vector.singleton (Content.AssistantToolCall (Content.ToolCall "objective-write" "objectives" (Aeson.object ["tag" .= ("RecordProgress" :: Text), "objectiveId" .= target, "expectedRevision" .= (2 :: Integer), "assignmentId" .= assignment, "state" .= ("Working" :: Text), "decisions" .= ([] :: [Text]), "assumptions" .= ([] :: [Text])]))))
          else do
            assertBool "the model receives the scope/membership denial" ("ObjectiveDenied" `Text.isInfixOf` Text.decodeUtf8 (Lazy.toStrict (Aeson.encode context)))
            pure response
      provider = stubApiProvider & #complete .~ complete & #stream .~ liftCompleteToStream complete
      key = checked parseRequestKey "member-objective-run"
      job = addressedRunJob now actor declaration.name AgentWorkflowRoute (Aeson.object []) (Ledger.httpRunKey declaration.name key) & #objective .~ Just (ObjectiveAssociation originalGoal assignmentKey)
  registry <- Provider.newProviderRegistryFrom [provider]
  let configured = base & #providerRegistry .~ Just registry
      dependencies = (RouterFixture.routerDeps env configured (Routing.RoutingRuntime (\_ -> pure RouterFixture.catalog) (\_ _ _ -> error "unused routing")) [declaration]) & #directory .~ directory & #objectives .~ Just runtime & #coordination .~ Just coordination & #decisions . #providers .~ [provider] & #deliveryPool .~ Just store.pool
      execution = Replay.executionIdFor (assignmentIdFor (runJobWorkflowId job).unWorkflowId)
  _ <- Ledger.acceptObjectiveRunRequest settings store.pool job key (Ledger.callerAttribution "objective-source-owner") >>= right
  Agent.runAgentRunWorkflow dependencies job >>= (@?= Right Suspended)
  access <- Fixture.run env (Execution.authorizeReplay execution actor (Directory.identityLifecycleAdmission directory actor)) >>= right
  (before, _) <- Fixture.run env (Execution.loadExecution access) >>= right
  when revoke do
    _ <- Objectives.owned runtime (Goal.executeCommand owner originalGoal (checked O.parseRevision 2) (checked parseOperationId "revoke-before-dispatch") (Command.RevokeMember (O.RecordedAgent actor))) >>= right
    pure ()
  completed <- SelectionFixture.driveExecutionChild env (Agent.executionRuntime dependencies) execution 40
  assertBool (show completed) (completed.phase == Replay.Succeeded)
  actual <- Objectives.owned runtime (Goal.readObjective owner target) >>= right
  actual.revision @?= checked O.parseRevision (if revoke then 3 else 2)
  ((head actual.assignments).definition).state @?= O.Pending
  (after, _) <- Fixture.run env (Execution.loadExecution access) >>= right
  after.toolBindings @?= before.toolBindings
  after.objectiveScope @?= before.objectiveScope
  readIORef calls >>= (@?= 2)

skillCreation :: DatabaseFixture -> IO ()
skillCreation fixture = skillScenario fixture AuthorizedCreator

data SkillScenario = AuthorizedCreator | DeniedCreator | UnavailableOwner deriving stock (Eq)

skillScenario :: DatabaseFixture -> SkillScenario -> IO ()
skillScenario fixture scenario = Fixture.withConfiguredResourceFixture fixture id (Map.insert Resources.Tokens Resources.ExplicitlyUnbounded) \env seed _ -> withStore env.connectionSettings \store -> do
  ensureRunQueue store.pool >>= right
  -- Disable both hybrid and fallback memory reads in this disposable database.
  -- Session/turn ownership remains live and independent of the learning view.
  sql env "ALTER TABLE kioku.memories RENAME TO memories_disabled_fixture"
  now <- getCurrentTime
  base <- newBehaviorEnv
  calls <- newIORef (0 :: Int)
  laterTarget <- newIORef Nothing
  laterObserved <- newIORef ([] :: [Aeson.Value])
  lostCreation <- newIORef False
  creationReplies <- newIORef ([] :: [Aeson.Value])
  let principal = checked mkAgentPrincipal "agent_objectives_skill"
      actor = VerifiedIdentity principal
      declaration = (RouterFixture.successSpecialist "worker") & #identity .~ Just (IdentityDecl (declarationCoordinate "agent_objectives_skill")) & #behavior .~ Skill (declarationCoordinate "../agents/skills/triage-note") & #memory . #recordPolicy .~ Never
      job = addressedRunJob now actor declaration.name AgentWorkflowRoute (Aeson.object []) (checked parseRunKey "objective-skill-consumer") & #executionRootId .~ seed.selection.rootId
      settings = O.defaultObjectiveSettings & #enabled .~ O.ObjectivesEnabled & #agentCreation .~ [principal | scenario /= DeniedCreator]
      complete model context options = do
        ordinal <- atomicModifyIORef' calls (\n -> (n + 1, n))
        response <- Provider.complete stubApiProvider model context options
        request <- case ordinal of
          0 -> pure (Just createInput)
          _ | scenario == DeniedCreator -> pure Nothing
          1 -> Just . planInput <$> goalFromContext context
          2 -> Just . progressInput <$> goalFromContext context
          3 -> Just . inspectInput <$> goalFromContext context
          5 -> fmap inspectInput <$> readIORef laterTarget
          6 -> do
            modifyIORef' laterObserved (<> [toJSON context])
            pure Nothing
          _ -> pure Nothing
        pure case request of
          Nothing -> response
          Just arguments -> response & #message . #stopReason .~ ToolUse & #message . #content .~ Vector.singleton (Content.AssistantToolCall (Content.ToolCall ("skill-objectives-" <> Text.pack (show ordinal)) "objectives" arguments))
      provider = stubApiProvider & #complete .~ complete & #stream .~ liftCompleteToStream complete
  registry <- Provider.newProviderRegistryFrom [provider]
  directory <- Directory.newDirectoryHandle (Directory.staticDirectorySource [Directory.PrincipalRecord (declarationCoordinate "agent_objectives_skill") (declarationCoordinate "worker") Directory.Active])
  Directory.refreshDirectory directory >>= (@?= Right ())
  let runtime = Objectives.ObjectiveRuntime env settings directory allowAllActionAuthorizerForTests Nothing
      configured = base & #providerRegistry .~ Just registry
      dependencies = (RouterFixture.routerDeps env configured (Routing.RoutingRuntime (\_ -> pure RouterFixture.catalog) (\_ _ _ -> error "unused routing")) [declaration]) & #directory .~ directory & #objectives .~ Just runtime & #decisions . #providers .~ [provider] & #deliveryPool .~ Just store.pool
      execution = Replay.executionIdFor (assignmentIdFor (runJobWorkflowId job).unWorkflowId)
      originalExecutor = Agent.executionRuntime dependencies
      executor = originalExecutor {Executor.withTools = \snapshot context requested use -> case originalExecutor of Executor.ExecutionRuntime {withTools = actual} -> actual snapshot context requested (use . map wrap)}
      wrap bound =
        bound
          { Executor.tool = DynTool (someToolName bound.tool) (someToolDescription bound.tool) (someToolSchema bound.tool) \arguments -> do
              output <- runErasedOutput bound.tool arguments
              when (tag arguments == Just "CreateObjective") do
                case output of
                  Right rich -> unsafeEff_ (modifyIORef' creationReplies (<> [fromMaybe Aeson.Null rich.structuredContent]))
                  Left _ -> pure ()
                first <- unsafeEff_ (atomicModifyIORef' lostCreation (\old -> (True, not old)))
                when first (unsafeEff_ (throwIO (TransientBehaviorFailure "lost accepted Skill creation acknowledgement")))
              pure output
          }
  if scenario == UnavailableOwner
    then do
      sql env "ALTER TABLE shikigami.objectives RENAME TO objectives_unavailable_fixture"
      refused <- try (Agent.runAgentRunWorkflow dependencies job)
      assertBool "source failure is retryable before dispatch" (case refused of Left (_ :: SomeException) -> True; Right (Left _) -> True; _ -> False)
      sql env "ALTER TABLE shikigami.objectives_unavailable_fixture RENAME TO objectives"
      readIORef calls >>= (@?= 0)
      Fixture.run env (Execution.inspectExecution execution) >>= (@?= Right Nothing)
    else do
      Agent.runAgentRunWorkflow dependencies job >>= (@?= Right Suspended)
      access <- Fixture.run env (Execution.authorizeReplay execution actor (Directory.identityLifecycleAdmission directory actor)) >>= right
      (originalSnapshot, _) <- Fixture.run env (Execution.loadExecution access) >>= right
      completed <- SelectionFixture.driveExecutionChild env executor execution 80
      assertBool (show completed) (completed.phase == if scenario == DeniedCreator then Replay.Failed else Replay.Succeeded)
      finished <- Agent.runAgentRunWorkflow dependencies job
      assertBool (show finished) (case finished of Right (Completed result) -> if scenario == DeniedCreator then isLeft result else isRight result; _ -> False)
      goals <- Objectives.owned runtime (Goal.listObjectives (Objectives.hostFor runtime actor) Nothing 20) >>= right
      length goals @?= if scenario == DeniedCreator then 0 else 1
      when (scenario == AuthorizedCreator) ((head goals).revision @?= checked O.parseRevision 2)
      readIORef calls >>= (@?= if scenario == DeniedCreator then 1 else 5)
      index <- Fixture.run env (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId job) 0)
      assertBool "durable admission owns the work" (Map.member "admit-skill-execution" index && Map.notMember "run-behavior-v2" index)
      Map.lookup "recall" index @?= Just (toJSON ([] :: [Aeson.Value]))
      when (scenario == AuthorizedCreator) do
        replies <- readIORef creationReplies
        length replies @?= 2
        head replies @?= last replies
        (retained, _) <- Fixture.run env (Execution.loadExecution access) >>= right
        retained.toolBindings @?= originalSnapshot.toolBindings
        retained.objectiveScope @?= originalSnapshot.objectiveScope
        let goal = (head goals).objectiveId
            caller = checked O.parseCallerId "objective-continuity"
            owner = Objectives.hostFor runtime actor
            key = checked parseRequestKey "later-objective-run"
            reference = ObjectiveAssociation goal (checked O.parseObjectiveAssignmentId "own-work")
            laterJob = addressedRunJob now actor declaration.name AgentWorkflowRoute (Aeson.object []) (Ledger.httpRunKey declaration.name key) & #objective .~ Just reference & #executionRootId .~ seed.selection.rootId
            laterRuntime = runtime & #settings . #agentCreation .~ []
            laterDependencies = dependencies & #objectives .~ Just laterRuntime
            laterExecution = Replay.executionIdFor (assignmentIdFor (runJobWorkflowId laterJob).unWorkflowId)
        _ <- Objectives.owned runtime (Goal.executeCommand owner goal (checked O.parseRevision 2) (checked parseOperationId "grant-later-run") (Command.GrantMember (O.VerifiedCaller caller) [O.Coordinator])) >>= right
        _ <- Ledger.acceptObjectiveRunRequest settings store.pool laterJob key (Ledger.callerAttribution "objective-continuity") >>= right
        atomicModifyIORef' laterTarget (const (Just goal, ()))
        Agent.runAgentRunWorkflow laterDependencies laterJob >>= (@?= Right Suspended)
        later <- SelectionFixture.driveExecutionChild env (Agent.executionRuntime laterDependencies) laterExecution 40
        assertBool (show later) (later.phase == Replay.Succeeded)
        resumed <- Agent.runAgentRunWorkflow laterDependencies laterJob
        assertBool (show resumed) (case resumed of Right (Completed (Right _)) -> True; _ -> False)
        laterIndex <- Fixture.run env (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId laterJob) 0)
        Map.lookup "recall" laterIndex @?= Just (toJSON ([] :: [Aeson.Value]))
        readIORef calls >>= (@?= 7)
        observed <- readIORef laterObserved
        assertBool "the later model sees current progress without memory" (any (containsRevision 3) observed)

flowCreation :: DatabaseFixture -> Bool -> IO ()
flowCreation fixture loseAcknowledgement = Fixture.withFixture fixture \env _ _ -> do
  now <- getCurrentTime
  base <- newBehaviorEnv
  let principal = checked mkAgentPrincipal "agent_objectives_flow"
      actor = VerifiedIdentity principal
      declaration = (RouterFixture.successSpecialist "worker") & #identity .~ Just (IdentityDecl (declarationCoordinate "agent_objectives_flow")) & #behavior .~ Flow (declarationCoordinate "objective-example") & #memory . #recordPolicy .~ Never
      job = addressedRunJob now actor declaration.name AgentWorkflowRoute (Aeson.object []) (checked parseRunKey "objective-flow-consumer")
      settings = O.defaultObjectiveSettings & #enabled .~ O.ObjectivesEnabled & #agentCreation .~ [principal]
  directory <- Directory.newDirectoryHandle (Directory.staticDirectorySource [Directory.PrincipalRecord (declarationCoordinate "agent_objectives_flow") (declarationCoordinate "worker") Directory.Active])
  Directory.refreshDirectory directory >>= (@?= Right ())
  let runtime = Objectives.ObjectiveRuntime env settings directory allowAllActionAuthorizerForTests Nothing
      dependencies = (RouterFixture.routerDeps env base (Routing.RoutingRuntime (\_ -> pure RouterFixture.catalog) (\_ _ _ -> error "unused routing")) [declaration]) & #directory .~ directory & #objectives .~ Just runtime
  when loseAcknowledgement do
    sql env "CREATE FUNCTION shikigami.reject_objective_flow_ack() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.step_name = 'objectives-example-create' THEN RAISE EXCEPTION 'injected objective reply journal failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER reject_objective_flow_ack BEFORE INSERT ON keiro.keiro_workflow_steps FOR EACH ROW EXECUTE FUNCTION shikigami.reject_objective_flow_ack()"
    crashed <- try (Agent.runAgentRunWorkflow dependencies job)
    case crashed of
      Left (_ :: SomeException) -> pure ()
      Right (Left _) -> pure ()
      Right other -> assertFailure ("creation should lose its journal acknowledgement: " <> show other)
    goals <- Objectives.owned runtime (Goal.listObjectives (Objectives.hostFor runtime actor) Nothing 20) >>= right
    length goals @?= 1
    (head goals).revision @?= checked O.parseRevision 0
    sql env "DROP TRIGGER reject_objective_flow_ack ON keiro.keiro_workflow_steps"
  let resumedRuntime = if loseAcknowledgement then runtime & #settings . #agentCreation .~ [] else runtime
  finished <- Agent.runAgentRunWorkflow (dependencies & #objectives .~ Just resumedRuntime) job
  output <- case finished of
    Right (Completed (Right result)) -> pure result.behaviorOutput
    other -> assertFailure ("objective Flow should complete: " <> show other)
  goal <- goalFromValue output >>= maybe (fail "Flow returned no objective") pure
  goals <- Objectives.owned runtime (Goal.listObjectives (Objectives.hostFor runtime actor) Nothing 20) >>= right
  length goals @?= 1
  let actual = head goals
  actual.objectiveId @?= goal
  actual.revision @?= checked O.parseRevision 2
  ((head actual.assignments).definition).state @?= O.Working
  index <- Fixture.run env (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId job) 0)
  assertBool "real policy and static objective steps are journaled" (all (`Map.member` index) ["objectives-policy", "objectives-example-create", "objectives-example-plan", "objectives-example-progress", "objectives-example-inspect"])

sql :: AppEnv -> Text -> IO ()
sql env statement = Fixture.run env (runTransaction (Tx.sql (Text.encodeUtf8 statement)))

nativeCreation :: DatabaseFixture -> Bool -> IO ()
nativeCreation fixture loseAcknowledgement = nativeScenario fixture loseAcknowledgement False

nativeScenario :: DatabaseFixture -> Bool -> Bool -> IO ()
nativeScenario fixture loseAcknowledgement holdInspection = Fixture.withConfiguredResourceFixture fixture id (Map.insert Resources.Tokens Resources.ExplicitlyUnbounded) \env seed _ -> do
  withStore env.connectionSettings (\store -> ensureRunQueue store.pool >>= right)
  now <- getCurrentTime
  let principal = checked mkAgentPrincipal "agent_objectives_native"
      actor = VerifiedIdentity principal
      declaration = (RouterFixture.successSpecialist "worker") {identity = Just (IdentityDecl (declarationCoordinate "agent_objectives_native")), behavior = Skill (declarationCoordinate "unused-native-fixture")}
      job = addressedRunJob now actor declaration.name AgentWorkflowRoute (Aeson.object []) (checked parseRunKey "objective-native-consumer") & #executionRootId .~ seed.selection.rootId & #executionPermissions .~ Just seed.selection.permittedAliases
      assignment = assignmentIdFor (runJobWorkflowId job).unWorkflowId
      selection = seed.selection & #assignmentId .~ assignment & #rootId .~ (if holdInspection then Nothing else seed.selection.rootId)
      initial = seed & #executionId .~ Replay.executionIdFor assignment & #runId .~ runJobWorkflowId job & #identity .~ actor & #selection .~ selection
      settings = O.defaultObjectiveSettings & #enabled .~ O.ObjectivesEnabled & #agentCreation .~ [principal]
  directory <- Directory.newDirectoryHandle (Directory.staticDirectorySource [Directory.PrincipalRecord (declarationCoordinate "agent_objectives_native") (declarationCoordinate "worker") Directory.Active])
  Directory.refreshDirectory directory >>= (@?= Right ())
  let runtime = Objectives.ObjectiveRuntime env settings directory allowAllActionAuthorizerForTests Nothing
  scope <- Objectives.resolveExecutionScope runtime job declaration initial.sessionId selection >>= right >>= maybe (fail "creator scope missing") pure
  scope.rootId @?= selection.rootId
  runtimeRef <- newIORef runtime
  lost <- newIORef False
  creations <- newIORef ([] :: [Aeson.Value])
  evidenceReplies <- newIORef ([] :: [Aeson.Value])
  lostEvidence <- newIORef False
  dispatch <- newIORef Nothing
  lateInspection <- newIORef Nothing
  lostInspection <- newIORef False
  modelCalls <- newIORef (0 :: Int)
  let currentFactory =
        Native.NativeToolFactory
          { Native.describe = \snapshot -> readIORef runtimeRef >>= \current -> (Tools.objectiveTools (Just current)).describe snapshot,
            Native.prepare = \snapshot context requested -> do
              current <- readIORef runtimeRef
              prepared <- (Tools.objectiveTools (Just current)).prepare snapshot context requested
              pure (fmap (map wrap) prepared)
          }
      wrap bound =
        bound
          { Executor.tool = DynTool (someToolName bound.tool) (someToolDescription bound.tool) (someToolSchema bound.tool) \arguments -> do
              output <- runErasedOutput bound.tool arguments
              when (tag arguments == Just "CreateObjective") do
                case output of
                  Right rich -> unsafeEff_ (modifyIORef' creations (<> [fromMaybe Aeson.Null rich.structuredContent]))
                  Left err -> unsafeEff_ (assertFailure (show err))
                first <- unsafeEff_ (atomicModifyIORef' lost (\old -> (True, not old)))
                when (loseAcknowledgement && first) $ unsafeEff_ do
                  atomicModifyIORef' runtimeRef (\old -> (old & #settings . #agentCreation .~ [], ()))
                  throwIO (TransientBehaviorFailure "fixture lost the acknowledgement after objective commit")
              when (tag arguments == Just "RecordEvidence") do
                case output of
                  Right rich -> unsafeEff_ (modifyIORef' evidenceReplies (<> [fromMaybe Aeson.Null rich.structuredContent]))
                  Left err -> unsafeEff_ (assertFailure (show err))
                first <- unsafeEff_ (atomicModifyIORef' lostEvidence (\old -> (True, not old)))
                when (loseAcknowledgement && first) (unsafeEff_ (throwIO (TransientBehaviorFailure "lost evidence acknowledgement after commit")))
              when (tag arguments == Just "InspectObjective" && holdInspection) do
                first <- unsafeEff_ (atomicModifyIORef' lostInspection (\old -> (True, not old)))
                when first case output of
                  Right rich -> unsafeEff_ do
                    context <- readIORef dispatch >>= maybe (fail "missing real dispatch claim") pure
                    atomicModifyIORef' lateInspection (const (Just (context, Replay.captureToolOutput rich), ()))
                    throwIO (TransientBehaviorFailure "lost inspection acknowledgement without an immutable command receipt")
                  Left _ -> pure ()
              pure output
          }
  menu <- Native.describeExecutionTools Log.silentLogger allowAllActionAuthorizerForTests emptyCapabilityProviderRegistry currentFactory (initial & #objectiveScope .~ Just scope) >>= right
  let snapshot = initial & #objectiveScope .~ Just scope & #offeredTools .~ menu.offeredTools & #toolBindings .~ menu.toolBindings
  _ <- right =<< Fixture.run env (Execution.admitExecution snapshot)
  (base, _, _) <- Fixture.driverRuntime env False
  let complete model context options = do
        ordinal <- atomicModifyIORef' modelCalls (\n -> (n + 1, n))
        response <- Provider.complete stubApiProvider model context options
        request <- case ordinal of
          0 -> pure (Just createInput)
          1 -> Just . planInput <$> goalFromContext context
          2 -> Just . (if holdInspection then doneInput else progressInput) <$> goalFromContext context
          3 -> Just . evidenceInput <$> goalFromContext context
          4 -> Just . inspectInput <$> goalFromContext context
          _ -> pure Nothing
        pure case request of
          Nothing -> response
          Just arguments -> response & #message . #stopReason .~ ToolUse & #message . #content .~ Vector.singleton (Content.AssistantToolCall (Content.ToolCall ("objectives-" <> Text.pack (show ordinal)) "objectives" arguments))
      provider = stubApiProvider & #complete .~ complete & #stream .~ liftCompleteToStream complete
  registry <- Provider.newProviderRegistryFrom [provider]
  let original = base.selectionRuntime snapshot
      selected = original {providers = [provider], baseEnv = original.baseEnv & #providerRegistry .~ Just registry}
      executor =
        base
          { Executor.selectionRuntime = const selected,
            Executor.replayAuthority = Directory.identityLifecycleAdmission directory,
            Executor.authorize = \snapshot' -> Directory.identityLifecycleAdmission directory snapshot'.identity,
            Executor.withTools = \snapshot' context requested use -> do
              atomicModifyIORef' dispatch (const (Just context, ()))
              Native.withExecutionTools Log.silentLogger allowAllActionAuthorizerForTests emptyCapabilityProviderRegistry currentFactory snapshot' context requested use
          }
  when holdInspection do
    advanceUntilPending env executor snapshot 60
    goals <- Objectives.owned runtime (Goal.listObjectives (Objectives.hostFor runtime actor) Nothing 20) >>= right
    length goals @?= 1
    let current = head goals
        proposal = O.CompletionProposal current.revision current.instructionsRevision current.criteriaRevision [checked O.parseArtifactRef "combined-artifact"] [checked O.parseEvidenceKey "review-check"] []
        owner = Objectives.hostFor runtime actor
    current.revision @?= checked O.parseRevision 3
    current.unresolved @?= []
    _ <- Objectives.owned runtime (Goal.executeCommand owner current.objectiveId current.revision (checked parseOperationId "propose-with-unacknowledged-tool") (Command.ProposeCompletion proposal)) >>= right
    Objectives.owned runtime (Goal.executeCommand owner current.objectiveId (checked O.parseRevision 4) (checked parseOperationId "accept-after-source-settlement") Command.AcceptCompletion) >>= (@?= Left O.ObjectiveUnresolved)
  result <- Fixture.pumpDriver env executor snapshot 80
  assertBool (show result) (result.phase == Replay.Succeeded)
  calls <- readIORef creations
  length calls @?= if loseAcknowledgement then 2 else 1
  when loseAcknowledgement (assertBool "recovery returns the identical goal receipt" (head calls == last calls))
  goal <- goalFromValue (head calls) >>= maybe (fail "creation returned no objective") pure
  currentRuntime <- readIORef runtimeRef
  actual <- Objectives.owned currentRuntime (Goal.readObjective (Objectives.hostFor currentRuntime actor) goal) >>= right
  actual.revision @?= checked O.parseRevision (if holdInspection then 4 else 3)
  length actual.evidence @?= 1
  (head actual.evidence).recordedBy @?= O.RecordedAgent actor
  evidenceResults <- readIORef evidenceReplies
  length evidenceResults @?= if loseAcknowledgement then 2 else 1
  head evidenceResults @?= last evidenceResults
  length actual.assignments @?= 1
  let assigned = head actual.assignments
  assigned.definition.owner @?= actor
  assigned.definition.rootId @?= scope.rootId
  assigned.definition.cutoff @?= scope.cutoff
  assigned.definition.state @?= if holdInspection then O.Done else O.Working
  when holdInspection do
    let owner = Objectives.hostFor currentRuntime actor
        accept = Objectives.owned currentRuntime (Goal.executeCommand owner goal actual.revision (checked parseOperationId "accept-after-source-settlement") Command.AcceptCompletion)
    -- Logical success does not settle a superseded actual attempt. The original
    -- worker's retained output and real dispatch claim supply its late receipt.
    accept >>= (@?= Left O.ObjectiveUnresolved)
    (context, output) <- readIORef lateInspection >>= maybe (fail "missing retained late inspection receipt") pure
    access <- Fixture.run env (Execution.authorizeReplay snapshot.executionId actor (Directory.identityLifecycleAdmission directory actor)) >>= right
    (_, state) <- Fixture.run env (Execution.loadExecution access) >>= right
    let reference = Attempt.JobReference V1 snapshot.executionId context.operation.operationId context.attemptId
        claim = Attempt.AttemptClaim reference context.owner context.generation
        receipt = Attempt.AttemptResult (Replay.RichToolReturned output) Replay.NeedModel Nothing
    _ <- Fixture.run env (Execution.recordLateExecutionReceipt access state.revision claim receipt) >>= right
    (_, settled) <- Fixture.run env (Execution.loadExecution access) >>= right
    settled.pendingReceipts @?= noPendingReceipts
    accepted <- accept >>= right
    accept >>= (@?= Right accepted)
  (retained, _) <- Fixture.run env (Execution.authorizeReplay snapshot.executionId actor (Directory.identityLifecycleAdmission directory actor)) >>= right >>= \permit -> Fixture.run env (Execution.loadExecution permit) >>= right
  retained.toolBindings @?= snapshot.toolBindings
  retained.objectiveScope @?= Just scope
  access <- Fixture.run env (Execution.authorizeReplay snapshot.executionId actor (Directory.identityLifecycleAdmission directory actor)) >>= right
  (_, finalState) <- Fixture.run env (Execution.loadExecution access) >>= right
  finalState.pendingReceipts @?= noPendingReceipts

advanceUntilPending :: AppEnv -> Executor.ExecutionRuntime -> Replay.ExecutionSnapshot -> Int -> IO ()
advanceUntilPending env executor snapshot remaining
  | remaining <= 0 = assertFailure "fixture did not reach the real pending-receipt boundary"
  | otherwise = do
      Just (state, _, _) <- Fixture.run env (Execution.inspectExecution snapshot.executionId) >>= right
      if state.pendingReceipts /= noPendingReceipts
        then pure ()
        else do
          outcome <- Fixture.run env (runWorkflow DriverGenerated.workflowName (Replay.executionWorkflowId snapshot.executionId) (Driver.executionWorkflow executor (Just (Driver.ExecutionStart snapshot.executionId))))
          case outcome of
            ContinuedAsNew -> advanceUntilPending env executor snapshot (remaining - 1)
            Suspended -> do
              Just (current, _, _) <- Fixture.run env (Execution.inspectExecution snapshot.executionId) >>= right
              operation <- maybe (fail "no active operation") pure current.activeOperation
              attempts <- Fixture.run env (Execution.inspectOperationAttempts operation) >>= right
              case filter Attempt.logicalAttempt attempts of
                [attempt] -> Executor.executeAcceptedAttempt executor snapshot.identity (Attempt.JobReference V1 snapshot.executionId operation attempt.request.attemptId) >>= (@?= Right Executor.ExecutorDone)
                _ -> assertFailure "expected one current accepted attempt"
              advanceUntilPending env executor snapshot (remaining - 1)
            _ -> assertFailure (show outcome)

createInput :: Aeson.Value
createInput = Aeson.object ["tag" .= ("CreateObjective" :: Text), "request" .= Aeson.object ["title" .= ("Autonomous delivery" :: Text), "goal" .= ("Reviewed artifact" :: Text), "instructions" .= ("work" :: Text), "criteria" .= [Aeson.object ["key" .= ("review" :: Text), "description" .= ("Review combined artifact" :: Text), "kind" .= ("HumanVerifiable" :: Text), "journeyRequired" .= False]], "external" .= ([] :: [Aeson.Value])]]

planInput :: O.ObjectiveId -> Aeson.Value
planInput goal = Aeson.object ["tag" .= ("PlanAssignments" :: Text), "objectiveId" .= goal, "expectedRevision" .= (0 :: Int), "assignments" .= [Aeson.object ["assignmentId" .= assignment, "instructions" .= ("work" :: Text), "dependencies" .= ([] :: [Aeson.Value]), "state" .= ("Pending" :: Text)]]]

progressInput :: O.ObjectiveId -> Aeson.Value
progressInput goal = Aeson.object ["tag" .= ("RecordProgress" :: Text), "objectiveId" .= goal, "expectedRevision" .= (1 :: Int), "assignmentId" .= assignment, "state" .= ("Working" :: Text), "decisions" .= ([] :: [Text]), "assumptions" .= ([] :: [Text])]

doneInput :: O.ObjectiveId -> Aeson.Value
doneInput goal = case progressInput goal of Aeson.Object fields -> Aeson.Object (KeyMap.insert "state" (Aeson.String "Done") fields); value -> value

evidenceInput :: O.ObjectiveId -> Aeson.Value
evidenceInput goal = Aeson.object ["tag" .= ("RecordEvidence" :: Text), "objectiveId" .= goal, "expectedRevision" .= (2 :: Int), "assignmentId" .= assignment, "evidence" .= Aeson.object ["tag" .= ("Attestation" :: Text), "key" .= ("review-check" :: Text), "criterion" .= ("review" :: Text), "artifact" .= ("combined-artifact" :: Text), "statement" .= ("Reviewed combined artifact" :: Text), "journey" .= False]]

inspectInput :: O.ObjectiveId -> Aeson.Value
inspectInput goal = Aeson.object ["tag" .= ("InspectObjective" :: Text), "objectiveId" .= goal, "after" .= (0 :: Int), "limit" .= (20 :: Int)]

assignment :: Aeson.Value
assignment = Aeson.object ["value" .= ("own-work" :: Text)]

tag :: Aeson.Value -> Maybe Text
tag (Aeson.Object fields) = case KeyMap.lookup "tag" fields of Just (Aeson.String value) -> Just value; _ -> Nothing
tag _ = Nothing

goalFromContext :: Context.Context -> IO O.ObjectiveId
goalFromContext context = goalFromValue (toJSON context) >>= maybe (fail "model did not receive its authoritative objective reply") pure

goalFromValue :: Aeson.Value -> IO (Maybe O.ObjectiveId)
goalFromValue = pure . findGoal
  where
    findGoal (Aeson.Object fields) = case KeyMap.lookup "objectiveId" fields of
      Just (Aeson.String raw) -> either (const Nothing) Just (O.parseObjectiveId raw)
      _ -> first (map findGoal (KeyMap.elems fields))
    findGoal (Aeson.Array values) = first (map findGoal (Vector.toList values))
    findGoal (Aeson.String raw) = case Aeson.eitherDecodeStrict (Text.encodeUtf8 raw) of Right value -> findGoal value; Left _ -> Nothing
    findGoal _ = Nothing
    first [] = Nothing
    first (Just value : _) = Just value
    first (_ : rest) = first rest

checked :: (Show e) => (a -> Either e b) -> a -> b
checked parser = either (error . show) id . parser

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure
