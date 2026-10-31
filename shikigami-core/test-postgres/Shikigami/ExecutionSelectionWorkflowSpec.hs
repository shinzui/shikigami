module Shikigami.ExecutionSelectionWorkflowSpec (tests, driveExecutionChild) where

import Baikai.Api (Api (Custom, OpenAIResponses))
import Baikai.Context (systemUser)
import Baikai.Evidence qualified as Evidence
import Baikai.Model qualified as Model
import Baikai.Models.Generated (allModels)
import Baikai.Options qualified as Options
import Baikai.Response (Response (..), responseError)
import Baikai.ThinkingLevel (ThinkingLevel (ThinkingHigh, ThinkingLow, ThinkingMedium))
import Control.Concurrent.Async (concurrently)
import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.Aeson (Value, eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.IORef
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Outbox (listOutbox)
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowOutcome (..), loadStepIndex)
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Keiro.Workflow.Awakeable.Schema (AwakeableRow (..), lookupAwakeable, registerAwakeableTx)
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Keiro.Workflow.Child (runChildWorkflow)
import Kioku.Id (genSessionId)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Network.HTTP.Types (status200, status500)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.Run (AgentRunResult)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.Behavior.Run (BehaviorEnv (..), completeBehaviorRequest, newBehaviorEnv)
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Capability.Overlay (emptyResolvedCapabilitySet)
import Shikigami.Decision.Contract (ModelAlias (..), ModelDescriptor (..), versionedDigest)
import Shikigami.Decision.ModelCatalog
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Counter (AttemptCount, AttemptLimit, noAttempts, parseAttemptCount, parseAttemptLimit)
import Shikigami.Execution.Driver qualified as Driver
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Foreground (driveExecutionForeground)
import Shikigami.Execution.Identity
import Shikigami.Execution.Policy (ModelOperationInput (..), selectContextView)
import Shikigami.Execution.Policy.Types (RecoveryClass (RepeatableObservation), defaultHarnessPolicy)
import Shikigami.Execution.Policy.Types qualified as Harness
import Shikigami.Execution.Quantity (ResourceAmount, parseResourceAmount)
import Shikigami.Execution.Request
import Shikigami.Execution.Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Selection
import Shikigami.Execution.SelectionRuntime
import Shikigami.Execution.SelectionStore qualified as Calls
import Shikigami.Execution.Store qualified as Durable
import Shikigami.Execution.Transcript qualified as Replay
import Shikigami.ExecutionDriver.Generated.WorkflowRuntime qualified as DriverGenerated
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Integration.Danwa (AddressedMessage (..))
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Prelude ((&), (.~))
import Shikigami.RouterWorkflowSpec qualified as Fixture
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Sink.Config (DanwaConfig (..))
import Shikigami.Sink.GrantStore (GrantSource (StaticGrants))
import Shikigami.Sink.Permission (SinkKind (SDanwaConversation))
import Shikigami.StateRevision (StateRevision, parseRevision)
import Shikigami.Trigger.Enqueue (ensureRunQueue)
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "ExecutionSelectionWorkflow"
    [ testCase "three admitted aliases reach HTTP with distinct model and thinking tuples" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          now <- getCurrentTime
          root <- seed app now []
          let catalog = mustRight (modelCatalog bindings)
          selections <-
            mapM
              ( \alias -> do
                  let selection = select now root catalog alias
                  selected <- expectRight =<< buildExecutionEnv (runtime app store base catalog) selection
                  response <- completeBehaviorRequest selected selected.model (systemUser "system" "marker") selected.options
                  responseError response @?= Nothing
                  Just (assignment, facts) <- run app (Calls.inspectSelection selection.assignmentId)
                  assignment.attempts @?= (fixtureCount 1)
                  assignment.active @?= (fixtureCount 0)
                  assignment.unknown @?= (fixtureCount 1)
                  length facts @?= 1
                  (head facts).receipt.rootId @?= Just root
                  assertBool "request digest only" (not ("marker" `Text.isInfixOf` Text.pack (show facts)))
                  assertBool "stored inspection sources exclude credentials" (not ("fixture-secret" `Text.isInfixOf` Text.pack (show (encode (assignment, facts)))))
                  ((head facts).outcome >>= (.reportedModel)) @?= Just "served-model"
                  pure selection
              )
              aliases
          bodies <- observed
          length bodies @?= 3
          map (\v -> lookupField "model" v) bodies @?= map (Just . Model.modelId . bindingModel) bindings
          map (\v -> lookupReasoning v) bodies @?= map Just ["low", "medium", "high"]
          snapshot <- expectRight =<< run app (Roots.inspectRoot root)
          snapshot.active @?= (fixtureCount 0)
          Map.lookup ModelAttempts snapshot.usage.settled @?= Just (fixtureAmount 3)
          assertBool "different selection identities share one root" (all ((== Just root) . (.rootId)) selections),
      testCase "out-of-range HTTP usage retains its ceiling while valid usage settles exactly" $
        mapM_
          ( \(tokens, overflow) -> withRuntime fixture \app store base -> withHttpWithTokens tokens \bindings observed -> do
              now <- getCurrentTime
              root <- seed app now [(Tokens, Limited (fixtureAmount (toInteger (maxBound :: Int64))))]
              let catalog = mustRight (modelCatalog bindings)
                  selection = select now root catalog "coordinator"
              selected <- expectRight =<< buildExecutionEnv (runtime app store base catalog) selection
              response <- completeBehaviorRequest selected selected.model (systemUser "system" "marker") selected.options
              responseError response @?= Nothing
              length <$> observed >>= (@?= 1)
              snapshot <- expectRight =<< run app (Roots.inspectRoot root)
              snapshot.active @?= (fixtureCount 0)
              snapshot.unknown @?= (fixtureCount 1)
              Map.lookup ModelAttempts snapshot.usage.settled @?= Just (fixtureAmount 1)
              if overflow
                then do
                  Map.lookup Tokens snapshot.known @?= Nothing
                  assertBool "unrepresentable usage keeps its held ceiling" (maybe False (> fixtureAmount 0) (Map.lookup Tokens snapshot.usage.held))
                else do
                  Map.lookup Tokens snapshot.known @?= Just (fixtureAmount tokens)
                  Map.lookup Tokens snapshot.usage.held @?= Just (fixtureAmount 0)
          )
          [(2, False), (toInteger (maxBound :: Int64) + 1, True)],
      testCase "an accepted prepared HTTP attempt commits replay and accounting together once" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          now <- getCurrentTime
          root <- seed app now []
          session <- genSessionId
          let catalog = mustRight (modelCatalog bindings)
              selection = select now root catalog "coordinator"
              selectedRuntime = runtime app store base catalog
              execution = Replay.executionIdFor selection.assignmentId
              snapshot = Replay.ExecutionSnapshot 1 execution "prepared-http" (AgentName "worker") (compatibilityIdentity "worker") session selection Nothing (Replay.SkillInstructions "fixture" "system" "body") (Replay.ReplayContext 1 (Just "system") [Replay.UserTurn [Replay.TextBlock "marker"] Nothing]) emptyResolvedCapabilitySet (toJSON ([] :: [Value])) defaultHarnessPolicy [] Nothing
              operationId = Replay.operationIdFor execution (fixtureRevision 0)
              specification = Replay.OperationSpec operationId Replay.ModelTurn RepeatableObservation "model" (versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy)) "scope" Nothing
              context = systemUser "system" "marker"
          _ <- expectRight =<< run app Catalog.registerProjectionCatalog
          run app (Durable.admitExecution snapshot) >>= (@?= Right Accepted)
          access <- expectRight =<< run app (Durable.authorizeReplay execution snapshot.identity (pure (Right ())))
          _ <- expectRight =<< run app (Durable.acceptOperation access (fixtureRevision 0) specification (toJSON context))
          (request, preparedCall) <- expectRight =<< preparePinnedExecutionCall selectedRuntime selection operationId (AttemptId "prepared-http-attempt") context Nothing
          let submission = Attempt.AttemptSubmission request (Just preparedCall) (Attempt.ExecutionWake (AwakeableId UUID.nil) 0)
              reference = Attempt.JobReference 1 execution operationId request.attemptId
          (_, attempt) <- expectRight =<< run app (Durable.submitExecutionAttemptWith access (fixtureRevision 1) submission (\_ -> pure ()))
          claim <-
            run app (Durable.claimExecutionAttempt access (fixtureRevision 2) reference "prepared-http-owner" 60) >>= \case
              Right (Attempt.ClaimGranted granted) -> pure granted
              other -> assertFailure (show other) >> fail "claim"
          run app (Durable.startExecutionAttempt access (fixtureRevision 3) claim) >>= (@?= Right Accepted)
          receipt <- maybe (assertFailure "missing reserved call" >> fail "receipt") pure attempt.call
          let commit _ accounting response = case response of
                Nothing -> assertFailure "expected terminal response"
                Just actual -> do
                  let outcome = Replay.ModelReturned (Replay.captureAssistant actual) (toJSON <$> actual.evidence)
                  ref <- expectRight (Durable.outcomeReference outcome)
                  run app (Durable.completeExecutionAttempt access (fixtureRevision 4) claim (Attempt.AttemptResult outcome (Replay.NeedValidation ref) (Just accounting))) >>= (@?= Right Accepted)
          selected <- expectRight =<< buildPreparedExecutionEnv selectedRuntime selection (PreparedSelectionCall receipt commit)
          response <- completeBehaviorRequest selected selected.model context selected.options
          responseError response @?= Nothing
          duplicate <- completeBehaviorRequest selected selected.model context selected.options
          assertBool "one prepared attempt cannot dispatch twice" (responseError duplicate /= Nothing)
          bodies <- observed
          length bodies @?= 1
          lookupField "model" (head bodies) @?= Just selection.descriptor.modelId
          (_, state) <- expectRight =<< run app (Durable.loadExecution access)
          state.cursor @?= (fixtureRevision 1)
          rootState <- expectRight =<< run app (Roots.inspectRoot root)
          rootState.active @?= (fixtureCount 0)
          Map.lookup ModelAttempts rootState.usage.settled @?= Just (fixtureAmount 1),
      testCase "executor restart repairs a lost wake without repeating the HTTP call" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          now <- getCurrentTime
          root <- seed app now []
          session <- genSessionId
          let catalog = mustRight (modelCatalog bindings)
              selection = select now root catalog "coordinator"
              selectedRuntime = runtime app store base catalog
              execution = Replay.executionIdFor selection.assignmentId
              snapshot = Replay.ExecutionSnapshot 1 execution "executor-http" (AgentName "worker") (compatibilityIdentity "worker") session selection Nothing (Replay.SkillInstructions "fixture" "system" "body") (Replay.ReplayContext 1 (Just "system") [Replay.UserTurn [Replay.TextBlock "marker"] Nothing]) emptyResolvedCapabilitySet (toJSON ([] :: [Value])) defaultHarnessPolicy [] Nothing
              operationId = Replay.operationIdFor execution (fixtureRevision 0)
              specification = Replay.OperationSpec operationId Replay.ModelTurn RepeatableObservation "model" (versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy)) "scope" Nothing
              executor authority = Executor.ExecutionRuntime app (const authority) (const authority) (const selectedRuntime) (\_ _ _ use -> Right <$> use []) 5
          _ <- expectRight =<< run app Catalog.registerProjectionCatalog
          run app (Durable.admitExecution snapshot) >>= (@?= Right Accepted)
          access <- expectRight =<< run app (Durable.authorizeReplay execution snapshot.identity (pure (Right ())))
          view <- expectRight (selectContextView snapshot.policy snapshot.initialContext)
          let input = ModelOperationInput 1 view Nothing Nothing
          (_, operation) <- expectRight =<< run app (Durable.acceptOperation access (fixtureRevision 0) specification (toJSON input))
          context <- expectRight (Executor.modelContext snapshot operation input)
          (request, preparedCall) <- expectRight =<< preparePinnedExecutionCall selectedRuntime selection operationId (AttemptId "executor-http-attempt") context Nothing
          let reference = Attempt.JobReference 1 execution operationId request.attemptId
          _ <- expectRight =<< run app (Durable.submitExecutionAttemptWith access (fixtureRevision 1) (Attempt.AttemptSubmission request (Just preparedCall) (Attempt.ExecutionWake (AwakeableId UUID.nil) 0)) (\_ -> pure ()))
          Executor.executeAcceptedAttempt (executor (pure (Right ()))) snapshot.identity reference >>= (@?= Left (Replay.ExecutionPolicyRefused "execution wake is unavailable"))
          (_, committed) <- expectRight =<< run app (Durable.loadExecution access)
          committed.cursor @?= (fixtureRevision 1)
          observed >>= (\bodies -> length bodies @?= 1)
          run app (runTransaction (registerAwakeableTx UUID.nil "shikigami.execution" (Replay.executionWorkflowId execution).unWorkflowId))
          -- A committed outcome needs no current provider/credential or new
          -- replay authorization to repair its already accepted wake.
          Executor.executeAcceptedAttempt (executor (pure (Left "revoked after commit"))) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          observed >>= (\bodies -> length bodies @?= 1)
          Just wake <- run app (lookupAwakeable UUID.nil)
          wake.status @?= Awakeable.Completed
          rootState <- expectRight =<< run app (Roots.inspectRoot root)
          rootState.active @?= (fixtureCount 0)
          Map.lookup ModelAttempts rootState.usage.settled @?= Just (fixtureAmount 1),
      testCase "a terminal HTTP error releases transport capacity while retaining unknown billing" $
        withRuntime fixture \app store base -> withHttpWithFailure True \bindings observed -> do
          now <- getCurrentTime
          root <- seed app now []
          let catalog = mustRight (modelCatalog bindings)
              selection = select now root catalog "coordinator"
          selected <- expectRight =<< buildExecutionEnv (runtime app store base catalog) selection
          response <- completeBehaviorRequest selected selected.model (systemUser "system" "marker") selected.options
          assertBool "terminal provider error" (responseError response /= Nothing)
          observed >>= (\bodies -> length bodies @?= 1)
          rootState <- expectRight =<< run app (Roots.inspectRoot root)
          rootState.active @?= (fixtureCount 0)
          rootState.unknown @?= (fixtureCount 1)
          Just (assignment, [call]) <- run app (Calls.inspectSelection selection.assignmentId)
          assignment.active @?= (fixtureCount 0)
          case call.outcome of Just outcome -> outcome.phase @?= Calls.CallTerminal; _ -> assertFailure "missing terminal call facts",
      testCase "fresh authority refusal after reservation sends no request" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          now <- getCurrentTime
          root <- seed app now []
          checks <- newIORef (0 :: Int)
          let catalog = mustRight (modelCatalog bindings)
              authority = atomicModifyIORef' checks (\n -> (n + 1, if n == 0 then Right () else Left "revoked"))
              selectedRuntime = (runtime app store base catalog) {authorize = authority}
              selection = select now root catalog "coordinator"
          selected <- expectRight =<< buildExecutionEnv selectedRuntime selection
          response <- completeBehaviorRequest selected selected.model (systemUser "system" "marker") selected.options
          assertBool "typed provider refusal" (responseError response /= Nothing)
          observed >>= (@?= [])
          snapshot <- expectRight =<< run app (Roots.inspectRoot root)
          snapshot.active @?= (fixtureCount 0)
          snapshot.unknown @?= (fixtureCount 0),
      testCase "callers cannot weaken a pinned binding evidence requirement" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          now <- getCurrentTime
          root <- seed app now []
          original <- case bindings of first : _ -> pure first; _ -> assertFailure "binding missing"
          let options = bindingOptions original & #evidence .~ Just (Evidence.evidenceRequest "pinned" & #strictness .~ Evidence.EvidenceRequired Evidence.EvidenceFullyObserved)
              strict = mustRight (modelBinding (ModelAlias "coordinator") "strict" "coordinator" "strict" (bindingModel original) options (bindingCredential original))
              catalog = mustRight (modelCatalog [strict])
          selected <- expectRight =<< buildExecutionEnv (runtime app store base catalog) (select now root catalog "coordinator")
          response <- completeBehaviorRequest selected selected.model (systemUser "system" "marker") (selected.options & #evidence .~ Nothing)
          assertBool "unsupported evidence refused" (responseError response /= Nothing)
          observed >>= (@?= []),
      testCase "unsupported hard cost ceiling refuses before dispatch" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          now <- getCurrentTime
          root <- seed app now [(CostMicroUsd, Limited (fixtureAmount 100))]
          let catalog = mustRight (modelCatalog bindings)
          selected <- expectRight =<< buildExecutionEnv (runtime app store base catalog) (select now root catalog "coordinator")
          response <- completeBehaviorRequest selected selected.model (systemUser "system" "marker") selected.options
          assertBool "refused" (responseError response /= Nothing)
          observed >>= (@?= [])
          snapshot <- expectRight =<< run app (Roots.inspectRoot root)
          snapshot.usage @?= emptyUsage,
      testCase "root and assignment race has one winner; replay and settlement are atomic" $
        withRuntime fixture \app _ _ -> do
          now <- getCurrentTime
          root <- seed app now [(ActiveWork, Limited (fixtureAmount 1))]
          let catalog = mustRight (modelCatalog [])
              fallback = mustRight (defaultBinding stubModel Options.emptyOptions)
              selection = mustRight (resolveExecutionSelection "ledger-assignment" catalog (Right fallback) Nothing Nothing Nothing Nothing (Just root) now)
              limits = Calls.CallLimits (Just (fixtureLimit 3)) (Just (fixtureLimit 1)) (Just (fixtureLimit 1)) Nothing Nothing
              request key = AttemptRequest (AttemptId key) (OperationId "logical") (Map.fromList [(ActiveWork, (fixtureAmount 1)), (ModelAttempts, (fixtureAmount 1))]) AdmittedUnknownUsage
              reserve key = run app (Calls.reserveSelectionCall selection limits (request key) "digest" now)
          (a, b) <- concurrently (reserve "one") (reserve "two")
          receipt <- case (a, b) of
            (Right (Calls.NewCall r), Left _) -> pure r
            (Left _, Right (Calls.NewCall r)) -> pure r
            other -> assertFailure (show other)
          run app (Calls.reserveSelectionCall selection limits receipt.request "digest" now) >>= (@?= Right (Calls.ExistingCall receipt))
          let terminal = Calls.CallOutcome Calls.CallTerminal (Map.singleton Tokens (fixtureAmount 3)) [CostMicroUsd] (Just "served") (Just "provider-call") Nothing
          run app (Calls.finishSelectionCall receipt terminal) >>= (@?= Right Accepted)
          run app (Calls.finishSelectionCall receipt terminal) >>= (@?= Right AlreadyAccepted)
          next <- expectRight =<< reserve "retry"
          retried <- case next of Calls.NewCall r -> pure r; _ -> assertFailure "new actual retry required"
          run app (Calls.finishSelectionCall retried terminal) >>= (@?= Right Accepted)
          reserve "exhausted" >>= (@?= Left Calls.CallRetryLimitExceeded)
          Just (assignment, facts) <- run app (Calls.inspectSelection selection.assignmentId)
          assignment.attempts @?= (fixtureCount 2)
          assignment.active @?= (fixtureCount 0)
          length facts @?= 2
          snapshot <- expectRight =<< run app (Roots.inspectRoot root)
          Map.lookup ModelAttempts snapshot.usage.settled @?= Just (fixtureAmount 2)
          Map.lookup Tokens snapshot.known @?= Just (fixtureAmount 6),
      testCase "assignment active-count underflow refuses before coupled root settlement" $
        refusedAssignmentSettlement fixture False,
      testCase "assignment unknown-count underflow refuses before coupled root reconciliation" $
        refusedAssignmentSettlement fixture True,
      testCase "new Skill parent awaits the driver and completes after its provider binding is retired" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          _ <- expectRight =<< run app Catalog.registerProjectionCatalog
          ensureRunQueue store.pool >>= expectRight
          let request = Fixture.routerJob "durable-skill-parent"
              dependencies = workflowDeps app store base (mustRight (modelCatalog bindings)) workerDecl
              execution = Replay.executionIdFor (assignmentIdFor (runJobWorkflowId request).unWorkflowId)
          Agent.runAgentRunWorkflow dependencies request >>= (@?= Right Suspended)
          let retained = mustRight (retainModelBindings (mustRight (modelCatalog [])) bindings)
              replacement = workflowDeps app store (base & #model . #modelId .~ "changed-process-default") retained workerDecl
          Just completed <- expectRight =<< driveExecutionForeground (Agent.executionRuntime replacement) (Driver.ExecutionStart execution) 20
          completed.phase @?= Replay.Succeeded
          observed >>= (\values -> length values @?= 1)
          let retired = workflowDeps app store (base & #model . #modelId .~ "changed-default") (mustRight (modelCatalog [])) workerDecl
          assertCompleted =<< Agent.runAgentRunWorkflow retired request
          assertCompleted =<< Agent.runAgentRunWorkflow retired request
          observed >>= (\values -> length values @?= 1)
          index <- run app (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId request) 0)
          assertBool "new admission journaled" (Map.member "admit-skill-execution" index)
          assertBool "coarse behavior branch unused" (Map.notMember "run-behavior-v2" index),
      testCase "a new pending Skill refuses a retired binding before model dispatch" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          _ <- expectRight =<< run app Catalog.registerProjectionCatalog
          ensureRunQueue store.pool >>= expectRight
          let request = Fixture.routerJob "durable-skill-retired-before-dispatch"
              dependencies = workflowDeps app store base (mustRight (modelCatalog bindings)) workerDecl
              execution = Replay.executionIdFor (assignmentIdFor (runJobWorkflowId request).unWorkflowId)
              retired = workflowDeps app store base (mustRight (modelCatalog [])) workerDecl
          Agent.runAgentRunWorkflow dependencies request >>= (@?= Right Suspended)
          completed <- driveExecutionChild app (Agent.executionRuntime retired) execution 20
          completed.phase @?= Replay.Failed
          completed.failure @?= Just (Replay.ExecutionPolicyRefused "pinned execution binding is unavailable")
          observed >>= (@?= [])
          outcome <- Agent.runAgentRunWorkflow retired request
          case outcome of
            Right (Completed (Left _)) -> pure ()
            other -> assertFailure (show other),
      testCase "forbidden user alias leaves provider request count unchanged" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          let request = Fixture.routerJob "selection-forbidden" & #executionRequest .~ Just (ExecutionRequest (Just "forbidden") Nothing Nothing)
          result <- Agent.runAgentRunWorkflow (workflowDeps app store base (mustRight (modelCatalog bindings)) workerDecl) request
          assertBool "named refusal" ("ExecutionAliasForbidden" `Text.isInfixOf` Text.pack (show result))
          observed >>= (@?= []),
      testCase "conversation rotation preserves root and user constraints without granting overlays" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          now <- getCurrentTime
          root <- seed app now []
          let declaration = workerDecl
              dependencies = workflowDeps app store base (mustRight (modelCatalog bindings)) declaration
              env =
                Conversation.ConversationEnv
                  { appEnv = app,
                    behaviorEnv = base,
                    decisions = dependencies.decisions,
                    deliveryPool = Just store.pool,
                    resolveRunProfile = dependencies.resolveRunProfile,
                    runTimeout = 30,
                    harness = Harness.defaultHarnessPolicy,
                    idleTimeout = 1800,
                    danwa = DanwaConfig "http://localhost:1" "participant",
                    agents = [declaration],
                    grants = StaticGrants (Map.singleton "router" (Set.singleton SDanwaConversation)),
                    directory = dependencies.directory
                  }
              context = ExecutionContext (Just root) (Just (ExecutionRequest (Just "worker-a") Nothing Nothing)) (Just ["worker-a"])
              message n = AddressedMessage "conv_selection" ("message" <> Text.pack (show n)) Nothing "human" ("request-" <> Text.pack (show n)) "participant" ("emb" <> Text.pack (show n)) "human" now
          _ <- expectRight =<< run app Catalog.registerProjectionCatalog
          ensureRunQueue store.pool >>= expectRight
          let firstMessage = message (1 :: Int)
              secondMessage = message (2 :: Int)
              workflowId = Conversation.conversationWorkflowId 0 firstMessage
              execution msg = Replay.executionIdFor (conversationAssignmentIdFor workflowId.unWorkflowId msg.messageId)
          Conversation.submitConversationTurnWithExecution env declaration (compatibilityIdentity "router") (Just context) firstMessage >>= (@?= Right Conversation.ConversationAccepted)
          -- Repeated delivery observes its accepted turn and leaves the
          -- successor's input promise pending, without another model attempt.
          Conversation.submitConversationTurnWithExecution env declaration (compatibilityIdentity "router") (Just context) firstMessage >>= (@?= Right Conversation.ConversationAccepted)
          observed >>= (@?= [])
          index <- run app (loadStepIndex Conversation.conversationWorkflowName workflowId 0)
          token <- case Map.lookup "awkid:next-message" index >>= (\value -> case Aeson.fromJSON value of Aeson.Success token -> Just token; _ -> Nothing) of
            Just token -> pure (token :: AwakeableId)
            Nothing -> assertFailure "missing successor wake" >> fail "wake"
          let AwakeableId tokenId = token
          Just awakeable <- run app (lookupAwakeable tokenId)
          awakeable.status @?= Awakeable.Pending
          _ <- driveExecutionChild app (Agent.executionRuntime dependencies) (execution firstMessage) 20
          let retired = (env & #decisions .~ (Decision.defaultDecisionServices (mustRight (modelCatalog []))))
          first <- expectRight =<< Conversation.runConversationTurnWithExecution retired declaration (compatibilityIdentity "router") (Just context) firstMessage
          Conversation.runConversationTurn retired declaration firstMessage >>= (@?= Right first)
          Conversation.submitConversationTurnWithExecution env declaration (compatibilityIdentity "router") Nothing secondMessage >>= (@?= Right Conversation.ConversationAccepted)
          _ <- driveExecutionChild app (Agent.executionRuntime dependencies) (execution secondMessage) 20
          second <- expectRight =<< Conversation.runConversationTurn env declaration secondMessage
          Conversation.runConversationTurn env declaration firstMessage >>= (@?= Right first)
          replies <- run app (listOutbox "shinzui/shikigami")
          length replies @?= 2
          first.sessionId @?= second.sessionId
          bodies <- observed
          map (lookupField "model") bodies @?= replicate 2 (Just (Model.modelId (bindingModel (bindings !! 1))))
          case bodies of
            [_, secondBody] -> assertBool "prior accepted turns are frozen in the next assignment" ("request-1" `Text.isInfixOf` TextEncoding.decodeUtf8 (Lazy.toStrict (encode secondBody)))
            _ -> assertFailure "conversation repeated provider work"
          refused <- Conversation.runConversationTurnWithExecution env declaration (compatibilityIdentity "router") (Just (context & #request .~ Just (ExecutionRequest (Just "worker-b") Nothing Nothing))) (message (3 :: Int))
          assertBool "context cannot change within epoch" (either (const True) (const False) refused)
          observed >>= (\after -> length after @?= 2)
          snapshot <- expectRight =<< run app (Roots.inspectRoot root)
          Map.lookup ModelAttempts snapshot.usage.settled @?= Just (fixtureAmount 2)
    ]

aliases :: [Text]
aliases = ["coordinator", "worker-a", "worker-b"]

workerDecl :: AgentDecl
workerDecl = Fixture.routerDecl & #behavior .~ Skill "../agents/skills/triage-note" & #routing .~ Nothing & #delegates .~ [] & #execution .~ Just (ExecutionPolicy "coordinator" aliases)

workflowDeps :: AppEnv -> KirokuStore -> BehaviorEnv -> ModelCatalog -> AgentDecl -> Agent.AgentRunDeps
workflowDeps app store base catalog declaration =
  (Fixture.routerDeps app base (Routing.RoutingRuntime (\_ -> pure Fixture.catalog) (\_ _ _ -> error "unused router")) [declaration])
    { Agent.decisions = Decision.defaultDecisionServices catalog,
      Agent.deliveryPool = Just store.pool
    }

runtime :: AppEnv -> KirokuStore -> BehaviorEnv -> ModelCatalog -> SelectionRuntime
runtime app store base catalog = SelectionRuntime catalog Nothing (Decision.defaultDecisionServices catalog).providers base (runCorrelationId "selection-fixture") (pure (Right ())) (selectionTransaction app (Just store.pool))

select :: UTCTime -> ExecutionRootId -> ModelCatalog -> Text -> ExecutionSelection
select now root catalog alias = mustRight (resolveExecutionSelection ("assignment:" <> alias) catalog (Left PinnedBindingUnavailable) (Just (ExecutionPolicy alias aliases)) Nothing Nothing Nothing (Just root) now)

seed :: AppEnv -> UTCTime -> [(Dimension, Limit)] -> IO ExecutionRootId
seed app now overrides = do
  let root = ExecutionRootId "selection-root"
      limits = Map.union (Map.fromList overrides) (Map.fromList [(d, ExplicitlyUnbounded) | d <- [minBound .. maxBound]])
  run app (Roots.enrollRoot root (Envelope limits (addUTCTime 3600 now))) >>= (@?= Right Accepted)
  pure root

withRuntime :: DatabaseFixture -> (AppEnv -> KirokuStore -> BehaviorEnv -> IO a) -> IO a
withRuntime fixture use = withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
  tracer <- noopTracer
  base <- newBehaviorEnv
  use (AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing) store base

withHttp :: ([ModelBinding] -> IO [Value] -> IO a) -> IO a
withHttp = withHttpWithFailure False

withHttpWithFailure :: Bool -> ([ModelBinding] -> IO [Value] -> IO a) -> IO a
withHttpWithFailure failResponse = withHttpUsage failResponse Nothing

withHttpWithTokens :: Integer -> ([ModelBinding] -> IO [Value] -> IO a) -> IO a
withHttpWithTokens tokens = withHttpUsage False (Just tokens)

withHttpUsage :: Bool -> Maybe Integer -> ([ModelBinding] -> IO [Value] -> IO a) -> IO a
withHttpUsage failResponse reportedTokens use = do
  requests <- newIORef []
  let application request respond = do
        body <- Wai.strictRequestBody request
        value <- expectRight (eitherDecode body)
        atomicModifyIORef' requests (\xs -> (xs <> [value], ()))
        respond (if failResponse then Wai.responseLBS status500 [("Content-Type", "application/json")] "{\"error\":{\"message\":\"fixture failure\"}}" else Wai.responseLBS status200 [("Content-Type", "text/event-stream")] frames)
  testWithApplication (pure application) \port -> do
    let models = take 3 [m | m <- allModels, Model.api m == OpenAIResponses, Model.provider m == "openai", Model.reasoning m]
        bindings = zipWith3 (\alias model thinking -> mustRight (modelBinding (ModelAlias alias) "1" alias "1" (model & #baseUrl .~ ("http://127.0.0.1:" <> Text.pack (show port) <> "/v1")) (Options.emptyOptions & #thinking .~ Just thinking & #maxTokens .~ (1024 <$ reportedTokens)) (Just (opaqueCredential "fixture-secret")))) aliases models [ThinkingLow, ThinkingMedium, ThinkingHigh]
    length bindings @?= 3
    use bindings (readIORef requests)
  where
    frames :: Lazy.ByteString
    frames = case reportedTokens of
      Nothing -> defaultFrames
      Just tokens ->
        "data: "
          <> encode
            ( object
                [ "type" .= ("response.completed" :: Text),
                  "response"
                    .= object
                      [ "id" .= ("fixture-call" :: Text),
                        "model" .= ("served-model" :: Text),
                        "output" .= [object ["id" .= ("message" :: Text), "type" .= ("message" :: Text), "role" .= ("assistant" :: Text), "content" .= [object ["type" .= ("output_text" :: Text), "text" .= ("marker" :: Text)]]]],
                        "usage" .= object ["input_tokens" .= tokens, "output_tokens" .= (0 :: Integer), "input_tokens_details" .= object ["cached_tokens" .= (0 :: Integer), "cache_write_tokens" .= (0 :: Integer)], "output_tokens_details" .= object ["reasoning_tokens" .= (0 :: Integer)]]
                      ]
                ]
            )
          <> "\n\n"
    defaultFrames :: Lazy.ByteString
    defaultFrames = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"fixture-call\",\"model\":\"served-model\",\"output\":[{\"id\":\"message\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"marker\"}]}]}}\n\n"

lookupField :: Text -> Value -> Maybe Text
lookupField key value = case eitherDecode (encode value) :: Either String (Map.Map Text Value) of
  Right fields -> Map.lookup key fields >>= \v -> either (const Nothing) Just (eitherDecode (encode v))
  _ -> Nothing

lookupReasoning :: Value -> Maybe Text
lookupReasoning value = do
  fields <- either (const Nothing) Just (eitherDecode (encode value) :: Either String (Map.Map Text Value))
  Map.lookup "reasoning" fields >>= lookupField "effort"

crashBeforeBehavior :: IO Agent.AgentRunHooks
crashBeforeBehavior = do
  once <- newIORef True
  pure
    ( Agent.defaultAgentRunHooks
        & #beforeStepBody
        .~ ( \(StepName name) -> when (name == "run-behavior-v2") do
               crash <- atomicModifyIORef' once (\current -> (False, current))
               when crash (ioError (userError "selection fixture crash"))
           )
    )

driveExecutionChild :: AppEnv -> Executor.ExecutionRuntime -> Replay.ExecutionId -> Int -> IO Driver.ExecutionDriverResult
driveExecutionChild app executor execution remaining
  | remaining <= 0 = assertFailure "execution child exceeded its bounded fixture" >> fail "driver child"
  | otherwise = do
      outcome <- run app (runChildWorkflow (shikigamiWorkflowRunOptions app) DriverGenerated.workflowName (Replay.executionWorkflowId execution) (Driver.executionWorkflow executor Nothing))
      case outcome of
        Completed value -> pure value
        ContinuedAsNew -> driveExecutionChild app executor execution (remaining - 1)
        Suspended -> do
          Just (state, binding, _) <- expectRight =<< run app (Durable.inspectExecution execution)
          operation <- maybe (assertFailure "driver suspended without active work" >> fail "operation") pure state.activeOperation
          attempts <- expectRight =<< run app (Durable.inspectOperationAttempts operation)
          case filter (\attempt -> attempt.phase /= Attempt.AttemptAbandoned) attempts of
            [attempt] -> Executor.executeAcceptedAttempt executor binding.identity (Attempt.JobReference 1 execution operation attempt.request.attemptId) >>= (@?= Right Executor.ExecutorDone)
            _ -> assertFailure "driver child has no accepted attempt"
          driveExecutionChild app executor execution (remaining - 1)
        _ -> assertFailure (show outcome) >> fail "driver child outcome"

assertCompleted :: (Show e, Show failure, Show a) => Either e (WorkflowOutcome (Either failure a)) -> IO ()
assertCompleted (Right (Completed (Right _))) = pure ()
assertCompleted other = assertFailure (show other)

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= expectRight

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

mustRight :: (Show e) => Either e a -> a
mustRight = either (error . show) id

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureAmount :: Integer -> ResourceAmount
fixtureAmount amount = either (error . show) id (parseResourceAmount amount)

fixtureCount :: Integer -> AttemptCount scope
fixtureCount count = either (error . show) id (parseAttemptCount count)

fixtureLimit :: Integer -> AttemptLimit scope
fixtureLimit number = either (error . show) id (parseAttemptLimit number)

-- Synthetic boundary state in the application-owned selection table. Both the
-- actual receipt and root are acquired through production admission first.
refusedAssignmentSettlement :: DatabaseFixture -> Bool -> IO ()
refusedAssignmentSettlement fixture reconcile = withRuntime fixture \app _ _ -> do
  now <- getCurrentTime
  root <- seed app now []
  let catalog = mustRight (modelCatalog [])
      fallback = mustRight (defaultBinding stubModel Options.emptyOptions)
      selection = mustRight (resolveExecutionSelection "counter-refusal" catalog (Right fallback) Nothing Nothing Nothing Nothing (Just root) now)
      limits = mustRight (Calls.callLimitsFor selection Nothing)
      request = AttemptRequest (AttemptId "counter-refusal") (OperationId "counter-operation") (Map.fromList [(ActiveWork, fixtureAmount 1), (ModelAttempts, fixtureAmount 1), (Tokens, fixtureAmount 10), (CostMicroUsd, fixtureAmount 0)]) EnforcedCeiling
      terminal = Calls.CallOutcome Calls.CallTerminal (Map.fromList [(Tokens, fixtureAmount 3), (CostMicroUsd, fixtureAmount 0)]) [] Nothing Nothing Nothing
  admitted <- expectRight =<< run app (Calls.reserveSelectionCall selection limits request "counter-fingerprint" now)
  receipt <- case admitted of Calls.NewCall value -> pure value; _ -> assertFailure "new admitted call expected"
  if reconcile
    then run app (Calls.finishSelectionCall receipt (Calls.CallOutcome Calls.CallTransportUnknown Map.empty [Tokens, CostMicroUsd] Nothing Nothing Nothing)) >>= (@?= Right Accepted)
    else pure ()
  Just (before, facts) <- run app (Calls.inspectSelection selection.assignmentId)
  beforeRoot <- expectRight =<< run app (Roots.inspectRoot root)
  let invalid = if reconcile then before & #unknown .~ noAttempts else before & #active .~ noAttempts
  run
    app
    ( runTransaction
        ( Tx.statement
            (toJSON invalid)
            ( preparable
                "UPDATE shikigami.execution_selections SET state=$1 WHERE assignment_id='counter-refusal'"
                (E.param (E.nonNullable E.jsonb))
                D.noResult
            )
        )
    )
  result <- run app (if reconcile then runTransaction (Calls.reconcileSelectionCallTx receipt terminal) else Calls.finishSelectionCall receipt terminal)
  assertBool "count underflow refused" (case result of Left (Calls.CallResourcesRefused (InvalidResourceRequest _)) -> True; _ -> False)
  run app (Calls.inspectSelection selection.assignmentId) >>= (@?= Just (invalid, facts))
  afterRoot <- expectRight =<< run app (Roots.inspectRoot root)
  afterRoot @?= beforeRoot
