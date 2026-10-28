module Shikigami.ExecutionSelectionWorkflowSpec (tests) where

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
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Effectful (Eff)
import Keiro.Workflow (PatchId (..), StepName (..), WorkflowId (..), WorkflowOutcome (..), WorkflowRunOptions (..), loadStepIndex, runWorkflowWith)
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Keiro.Workflow.Awakeable.Schema (AwakeableRow (..), lookupAwakeable, registerAwakeableTx)
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kioku.Id (genSessionId)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Transaction (runTransaction)
import Network.HTTP.Types (status200, status500)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.Behavior.Run (BehaviorEnv (..), completeBehaviorRequest, newBehaviorEnv)
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Capability.Overlay (emptyResolvedCapabilitySet)
import Shikigami.Decision.Contract (ModelAlias (..), ModelDescriptor (..), versionedDigest)
import Shikigami.Decision.ModelCatalog
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Identity
import Shikigami.Execution.Policy (ModelOperationInput (..), selectContextView)
import Shikigami.Execution.Policy.Types (RecoveryClass (RepeatableObservation), defaultHarnessPolicy)
import Shikigami.Execution.Request
import Shikigami.Execution.Resources
import Shikigami.Execution.Selection
import Shikigami.Execution.SelectionRuntime
import Shikigami.Execution.Store qualified as Durable
import Shikigami.Execution.Transcript qualified as Replay
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
import Shikigami.Store.ExecutionResources qualified as Roots
import Shikigami.Store.ExecutionSelection qualified as Calls
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
                  assignment.attempts @?= 1
                  assignment.active @?= 0
                  assignment.unknown @?= 1
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
          snapshot.active @?= 0
          Map.lookup ModelAttempts snapshot.usage.settled @?= Just 3
          assertBool "different selection identities share one root" (all ((== Just root) . (.rootId)) selections),
      testCase "an accepted prepared HTTP attempt commits replay and accounting together once" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          now <- getCurrentTime
          root <- seed app now []
          session <- genSessionId
          let catalog = mustRight (modelCatalog bindings)
              selection = select now root catalog "coordinator"
              selectedRuntime = runtime app store base catalog
              execution = Replay.executionIdFor selection.assignmentId
              snapshot = Replay.ExecutionSnapshot 1 execution "prepared-http" (AgentName "worker") (compatibilityIdentity "worker") session selection Nothing (Replay.SkillInstructions "fixture" "system" "body") (Replay.ReplayContext 1 (Just "system") [Replay.UserTurn [Replay.TextBlock "marker"] Nothing]) emptyResolvedCapabilitySet (toJSON ([] :: [Value])) defaultHarnessPolicy []
              operationId = Replay.operationIdFor execution 0
              specification = Replay.OperationSpec operationId Replay.ModelTurn RepeatableObservation "model" (versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy)) "scope" Nothing
              context = systemUser "system" "marker"
          _ <- expectRight =<< run app Catalog.registerProjectionCatalog
          run app (Durable.admitExecution snapshot) >>= (@?= Right Accepted)
          access <- expectRight =<< run app (Durable.authorizeReplay execution snapshot.identity (pure (Right ())))
          _ <- expectRight =<< run app (Durable.acceptOperation access 0 specification (toJSON context))
          (request, preparedCall) <- expectRight =<< preparePinnedExecutionCall selectedRuntime selection operationId (AttemptId "prepared-http-attempt") context Nothing
          let submission = Attempt.AttemptSubmission request (Just preparedCall) (Attempt.ExecutionWake (AwakeableId UUID.nil) 0)
              reference = Attempt.JobReference 1 execution operationId request.attemptId
          (_, attempt) <- expectRight =<< run app (Durable.submitExecutionAttemptWith access 1 submission (\_ -> pure ()))
          claim <-
            run app (Durable.claimExecutionAttempt access 2 reference "prepared-http-owner" 60) >>= \case
              Right (Attempt.ClaimGranted granted) -> pure granted
              other -> assertFailure (show other) >> fail "claim"
          run app (Durable.startExecutionAttempt access 3 claim) >>= (@?= Right Accepted)
          receipt <- maybe (assertFailure "missing reserved call" >> fail "receipt") pure attempt.call
          let commit _ accounting response = case response of
                Nothing -> assertFailure "expected terminal response"
                Just actual -> do
                  let outcome = Replay.ModelReturned (Replay.captureAssistant actual) (toJSON <$> actual.evidence)
                  ref <- expectRight (Durable.outcomeReference outcome)
                  run app (Durable.completeExecutionAttempt access 4 claim (Attempt.AttemptResult outcome (Replay.NeedValidation ref) (Just accounting))) >>= (@?= Right Accepted)
          selected <- expectRight =<< buildPreparedExecutionEnv selectedRuntime selection (PreparedSelectionCall receipt commit)
          response <- completeBehaviorRequest selected selected.model context selected.options
          responseError response @?= Nothing
          duplicate <- completeBehaviorRequest selected selected.model context selected.options
          assertBool "one prepared attempt cannot dispatch twice" (responseError duplicate /= Nothing)
          bodies <- observed
          length bodies @?= 1
          lookupField "model" (head bodies) @?= Just selection.descriptor.modelId
          (_, state) <- expectRight =<< run app (Durable.loadExecution access)
          state.cursor @?= 1
          rootState <- expectRight =<< run app (Roots.inspectRoot root)
          rootState.active @?= 0
          Map.lookup ModelAttempts rootState.usage.settled @?= Just 1,
      testCase "executor restart repairs a lost wake without repeating the HTTP call" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          now <- getCurrentTime
          root <- seed app now []
          session <- genSessionId
          let catalog = mustRight (modelCatalog bindings)
              selection = select now root catalog "coordinator"
              selectedRuntime = runtime app store base catalog
              execution = Replay.executionIdFor selection.assignmentId
              snapshot = Replay.ExecutionSnapshot 1 execution "executor-http" (AgentName "worker") (compatibilityIdentity "worker") session selection Nothing (Replay.SkillInstructions "fixture" "system" "body") (Replay.ReplayContext 1 (Just "system") [Replay.UserTurn [Replay.TextBlock "marker"] Nothing]) emptyResolvedCapabilitySet (toJSON ([] :: [Value])) defaultHarnessPolicy []
              operationId = Replay.operationIdFor execution 0
              specification = Replay.OperationSpec operationId Replay.ModelTurn RepeatableObservation "model" (versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy)) "scope" Nothing
              executor authority = Executor.ExecutionRuntime app (const authority) (const authority) (const selectedRuntime) (\_ _ _ use -> Right <$> use []) 5
          _ <- expectRight =<< run app Catalog.registerProjectionCatalog
          run app (Durable.admitExecution snapshot) >>= (@?= Right Accepted)
          access <- expectRight =<< run app (Durable.authorizeReplay execution snapshot.identity (pure (Right ())))
          view <- expectRight (selectContextView snapshot.policy snapshot.initialContext)
          let input = ModelOperationInput 1 view Nothing
          (_, operation) <- expectRight =<< run app (Durable.acceptOperation access 0 specification (toJSON input))
          context <- expectRight (Executor.modelContext snapshot operation input)
          (request, preparedCall) <- expectRight =<< preparePinnedExecutionCall selectedRuntime selection operationId (AttemptId "executor-http-attempt") context Nothing
          let reference = Attempt.JobReference 1 execution operationId request.attemptId
          _ <- expectRight =<< run app (Durable.submitExecutionAttemptWith access 1 (Attempt.AttemptSubmission request (Just preparedCall) (Attempt.ExecutionWake (AwakeableId UUID.nil) 0)) (\_ -> pure ()))
          Executor.executeAcceptedAttempt (executor (pure (Right ()))) snapshot.identity reference >>= (@?= Left (Replay.ExecutionPolicyRefused "execution wake is unavailable"))
          (_, committed) <- expectRight =<< run app (Durable.loadExecution access)
          committed.cursor @?= 1
          observed >>= (\bodies -> length bodies @?= 1)
          run app (runTransaction (registerAwakeableTx UUID.nil "shikigami.execution" (Replay.executionWorkflowId execution).unWorkflowId))
          -- A committed outcome needs no current provider/credential or new
          -- replay authorization to repair its already accepted wake.
          Executor.executeAcceptedAttempt (executor (pure (Left "revoked after commit"))) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          observed >>= (\bodies -> length bodies @?= 1)
          Just wake <- run app (lookupAwakeable UUID.nil)
          wake.status @?= Awakeable.Completed
          rootState <- expectRight =<< run app (Roots.inspectRoot root)
          rootState.active @?= 0
          Map.lookup ModelAttempts rootState.usage.settled @?= Just 1,
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
          rootState.active @?= 0
          rootState.unknown @?= 1
          Just (assignment, [call]) <- run app (Calls.inspectSelection selection.assignmentId)
          assignment.active @?= 0
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
          snapshot.active @?= 0
          snapshot.unknown @?= 0,
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
          root <- seed app now [(CostMicroUsd, Limited 100)]
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
          root <- seed app now [(ActiveWork, Limited 1)]
          let catalog = mustRight (modelCatalog [])
              fallback = mustRight (defaultBinding stubModel Options.emptyOptions)
              selection = mustRight (resolveExecutionSelection "ledger-assignment" catalog (Right fallback) Nothing Nothing Nothing Nothing (Just root) now)
              limits = Calls.CallLimits (Just 3) (Just 1) (Just 1) Nothing Nothing
              request key = AttemptRequest (AttemptId key) (OperationId "logical") (Map.fromList [(ActiveWork, 1), (ModelAttempts, 1)]) AdmittedUnknownUsage
              reserve key = run app (Calls.reserveSelectionCall selection limits (request key) "digest" now)
          (a, b) <- concurrently (reserve "one") (reserve "two")
          receipt <- case (a, b) of
            (Right (Calls.NewCall r), Left _) -> pure r
            (Left _, Right (Calls.NewCall r)) -> pure r
            other -> assertFailure (show other)
          run app (Calls.reserveSelectionCall selection limits receipt.request "digest" now) >>= (@?= Right (Calls.ExistingCall receipt))
          let terminal = Calls.CallOutcome Calls.CallTerminal (Map.singleton Tokens 3) [CostMicroUsd] (Just "served") (Just "provider-call") Nothing
          run app (Calls.finishSelectionCall receipt terminal) >>= (@?= Right Accepted)
          run app (Calls.finishSelectionCall receipt terminal) >>= (@?= Right AlreadyAccepted)
          next <- expectRight =<< reserve "retry"
          retried <- case next of Calls.NewCall r -> pure r; _ -> assertFailure "new actual retry required"
          run app (Calls.finishSelectionCall retried terminal) >>= (@?= Right Accepted)
          reserve "exhausted" >>= (@?= Left Calls.CallRetryLimitExceeded)
          Just (assignment, facts) <- run app (Calls.inspectSelection selection.assignmentId)
          assignment.attempts @?= 2
          assignment.active @?= 0
          length facts @?= 2
          snapshot <- expectRight =<< run app (Roots.inspectRoot root)
          Map.lookup ModelAttempts snapshot.usage.settled @?= Just 2
          Map.lookup Tokens snapshot.known @?= Just 6,
      testCase "pending workflow retains selection across changed catalog and default" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          let catalog = mustRight (modelCatalog bindings)
              declaration = workerDecl
              request = Fixture.routerJob "selection-pinned"
          hooks <- crashBeforeBehavior
          let original = (workflowDeps app store base catalog declaration) {Agent.hooks = hooks}
          first <- try @SomeException (Agent.runAgentRunWorkflow original request)
          assertBool "crash before first model call" (either (const True) (const False) first)
          observed >>= (@?= [])
          let replacement = mustRight (modelCatalog [])
              retained = mustRight (retainModelBindings replacement bindings)
              changed = base & #model . #modelId .~ "changed-process-default"
          result <- Agent.runAgentRunWorkflow (workflowDeps app store changed retained declaration) request
          assertCompleted result
          bodies <- observed
          length bodies @?= 1
          lookupField "model" (head bodies) @?= Just (Model.modelId (bindingModel (head bindings)))
          index <- run app (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId request) 0)
          assertBool "selection admission journaled" (Map.member "resolve-execution-selection" index),
      testCase "an old in-flight Skill keeps the real process-default branch on resume" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          hooks <- crashBeforeBehavior
          let request = Fixture.routerJob "selection-old-branch"
              dependencies = (workflowDeps app store base (mustRight (modelCatalog bindings)) workerDecl) {Agent.hooks = hooks}
              options = shikigamiWorkflowRunOptions app
              oldOptions = options & #activePatches .~ Set.delete (PatchId "shikigami-execution-selection-v1") options.activePatches
          first <- try @SomeException (run app (runWorkflowWith oldOptions Agent.agentRunWorkflowName (runJobWorkflowId request) (Agent.agentRunWorkflow dependencies (Just request))))
          assertBool "old branch suspended before model IO" (either (const True) (const False) first)
          assertCompleted =<< Agent.runAgentRunWorkflow (workflowDeps app store base (mustRight (modelCatalog [])) workerDecl) request
          observed >>= (@?= [])
          index <- run app (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId request) 0)
          assertBool "no selection admission in the old population" (not (Map.member "resolve-execution-selection" index)),
      testCase "pending workflow refuses unavailable immutable binding" $
        withRuntime fixture \app store base -> withHttp \bindings observed -> do
          hooks <- crashBeforeBehavior
          let request = Fixture.routerJob "selection-unavailable"
              original = (workflowDeps app store base (mustRight (modelCatalog bindings)) workerDecl) {Agent.hooks = hooks}
          _ <- try @SomeException (Agent.runAgentRunWorkflow original request)
          result <- Agent.runAgentRunWorkflow (workflowDeps app store base (mustRight (modelCatalog [])) workerDecl) request
          assertBool "named refusal" ("PinnedBindingUnavailable" `Text.isInfixOf` Text.pack (show result))
          observed >>= (@?= []),
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
                    idleTimeout = 1800,
                    danwa = DanwaConfig "http://localhost:1" "participant",
                    agents = [declaration],
                    grants = StaticGrants (Map.singleton "router" (Set.singleton SDanwaConversation)),
                    directory = dependencies.directory
                  }
              context = ExecutionContext (Just root) (Just (ExecutionRequest (Just "worker-a") Nothing Nothing)) (Just ["worker-a"])
              message n = AddressedMessage "conv_selection" ("message" <> Text.pack (show n)) Nothing "human" "marker" "participant" ("emb" <> Text.pack (show n)) "human" now
          first <- expectRight =<< Conversation.runConversationTurnWithExecution env declaration (compatibilityIdentity "router") (Just context) (message (1 :: Int))
          second <- expectRight =<< Conversation.runConversationTurn env declaration (message (2 :: Int))
          first.sessionId @?= second.sessionId
          bodies <- observed
          map (lookupField "model") bodies @?= replicate 2 (Just (Model.modelId (bindingModel (bindings !! 1))))
          refused <- Conversation.runConversationTurnWithExecution env declaration (compatibilityIdentity "router") (Just (context & #request .~ Just (ExecutionRequest (Just "worker-b") Nothing Nothing))) (message (3 :: Int))
          assertBool "context cannot change within epoch" (either (const True) (const False) refused)
          observed >>= (\after -> length after @?= 2)
          snapshot <- expectRight =<< run app (Roots.inspectRoot root)
          Map.lookup ModelAttempts snapshot.usage.settled @?= Just 2
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
  use (AppEnv (defaultConnectionSettings connection) tracer Nothing) store base

withHttp :: ([ModelBinding] -> IO [Value] -> IO a) -> IO a
withHttp = withHttpWithFailure False

withHttpWithFailure :: Bool -> ([ModelBinding] -> IO [Value] -> IO a) -> IO a
withHttpWithFailure failResponse use = do
  requests <- newIORef []
  let application request respond = do
        body <- Wai.strictRequestBody request
        value <- expectRight (eitherDecode body)
        atomicModifyIORef' requests (\xs -> (xs <> [value], ()))
        respond (if failResponse then Wai.responseLBS status500 [("Content-Type", "application/json")] "{\"error\":{\"message\":\"fixture failure\"}}" else Wai.responseLBS status200 [("Content-Type", "text/event-stream")] frames)
  testWithApplication (pure application) \port -> do
    let models = take 3 [m | m <- allModels, Model.api m == OpenAIResponses, Model.provider m == "openai", Model.reasoning m]
        bindings = zipWith3 (\alias model thinking -> mustRight (modelBinding (ModelAlias alias) "1" alias "1" (model & #baseUrl .~ ("http://127.0.0.1:" <> Text.pack (show port) <> "/v1")) (Options.emptyOptions & #thinking .~ Just thinking) (Just (opaqueCredential "fixture-secret")))) aliases models [ThinkingLow, ThinkingMedium, ThinkingHigh]
    length bindings @?= 3
    use bindings (readIORef requests)
  where
    frames :: Lazy.ByteString
    frames = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"fixture-call\",\"model\":\"served-model\",\"output\":[{\"id\":\"message\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"marker\"}]}]}}\n\n"

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
    Agent.defaultAgentRunHooks
      { Agent.beforeStepBody = \(StepName name) -> when (name == "run-behavior-v2") do
          crash <- atomicModifyIORef' once (\current -> (False, current))
          when crash (ioError (userError "selection fixture crash"))
      }

assertCompleted :: (Show e, Show failure, Show a) => Either e (WorkflowOutcome (Either failure a)) -> IO ()
assertCompleted (Right (Completed (Right _))) = pure ()
assertCompleted other = assertFailure (show other)

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= expectRight

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

mustRight :: (Show e) => Either e a -> a
mustRight = either (error . show) id
