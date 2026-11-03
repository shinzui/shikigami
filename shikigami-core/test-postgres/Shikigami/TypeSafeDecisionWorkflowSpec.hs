module Shikigami.TypeSafeDecisionWorkflowSpec (tests) where

import Control.Exception (SomeException, throwIO, try)
import Control.Lens ((&), (.~))
import Control.Monad (when)
import Data.Aeson (Result (..), fromJSON, toJSON)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Effectful (liftIO)
import Keiro.PGMQ qualified as Job
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowOutcome (..), loadStepIndex)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Behavior.Run (newBehaviorEnv)
import Shikigami.Decision.Contract
import Shikigami.Decision.Evidence
import Shikigami.Decision.ModelCatalog
import Shikigami.Fixture.TypeSafe
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Program.Decision
import Shikigami.Program.Decision.JudgmentExample
import Shikigami.RouterWorkflowSpec qualified as Fixture
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Trigger.Enqueue qualified as Enqueue
import Shikumi.Decision.Setting (DecisionSetting (..))
import Shikumi.Program (emptyParams, setDecisionSetting)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "TypeSafe judgments"
    [ testCase "real queue and restarted worker retain raw and rich committed answers without credentials or executables" $
        withTypeSafeFixture 200 0 fixtureResponse \server ->
          withShikigamiFreshDatabase fixture \connection -> do
            declaration <- mustRight <$> loadAgent "../agents/proof/shikumi-judgment-example.dhall"
            tracer <- noopTracer
            behavior <- newBehaviorEnv
            let request =
                  (Fixture.routerJob "typesafe-queue-restart")
                    { agentName = declaration.name,
                      identity = compatibilityIdentity declaration.name,
                      triggerPayload = toJSON fixtureTicket,
                      lineage = [declaration.name]
                    }
                catalog = fixtureCatalog server.endpoint
                services = Decision.defaultDecisionServices catalog
                routing = Routing.RoutingRuntime (\_ -> pure Fixture.catalog) (\_ _ _ -> error "judgment cannot route")
                app = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}
                make store selected hooks =
                  (Fixture.routerDeps app behavior routing [declaration])
                    { Agent.decisions = selected,
                      Agent.deliveryPool = Just store.pool,
                      Agent.hooks = hooks
                    }
                consume dependencies action = Job.withJobRuntime connection Nothing \runtime -> do
                  consumed <- newIORef (0 :: Int)
                  assertion <- newIORef Nothing
                  result <- Job.runJobEff runtime do
                    Job.ensureJobQueue RunJobs.runJob
                    Job.runJobOnce 1 RunJobs.runJob \queued -> do
                      outcome <- liftIO (try @SomeException (Agent.runAgentRunWorkflow dependencies queued))
                      liftIO (modifyIORef' consumed (+ 1))
                      checked <- liftIO (try @SomeException (action outcome))
                      case checked of
                        Right disposition -> pure disposition
                        Left failure -> liftIO (writeIORef assertion (Just failure)) >> pure Job.Done
                  _ <- either (assertFailure . show) pure result
                  readIORef assertion >>= maybe (pure ()) throwIO
                  readIORef consumed >>= (@?= 1)
            once <- newIORef True
            let crash =
                  ( Agent.defaultAgentRunHooks
                      & #beforeStepBody
                        .~ ( \(StepName name) -> when (name == "record") do
                               stop <- atomicModifyIORef' once (\old -> (False, old))
                               when stop (ioError (userError "worker exits after committed decision"))
                           )
                  )
            original <- withStore (defaultConnectionSettings connection) \store -> do
              _ <- either (assertFailure . show) pure =<< Enqueue.ensureRunQueue store.pool
              _ <- either (assertFailure . show) pure =<< Enqueue.enqueueRunJob store.pool request
              consume (make store services crash) \outcome -> do
                assertBool "first worker stopped before top-level completion" (case outcome of Right (Right (Completed (Right _))) -> False; _ -> True)
                pure (Job.Retry (Job.RetryDelay 0))
              readOutcome app request
            length (outcomeAnswers original) @?= 1
            length original.attempts @?= 1
            case original.result of Right _ -> pure (); Left _ -> assertFailure "committed rich result missing"
            server.requests >>= (\calls -> length calls @?= 1)
            let changed = judgmentProgramWithSettings "2" (setDecisionSetting "urgent" (NoulSetting 0.99) emptyParams)
                restarted =
                  services
                    { Decision.catalog = mustRight (modelCatalog []),
                      Decision.programs = mustRight (programRegistry [SomeProgram changed]),
                      Decision.codecs = mustRight (resultCodecRegistry [retainedCodec judgmentProgram]),
                      Decision.providers = []
                    }
            withStore (defaultConnectionSettings connection) \store -> do
              consume (make store restarted Agent.defaultAgentRunHooks) \outcome -> do
                case outcome of
                  Right (Right (Completed (Right output))) -> original.result @?= Right output.behaviorOutput
                  _ -> assertFailure "restarted worker did not replay the committed result"
                pure Job.Done
              restored <- readOutcome app request
              toJSON restored @?= toJSON original
              report <- either (assertFailure . show) pure =<< readDecisionReport (postgresDecisionEvidenceStore store.pool) (runCorrelationId (runJobWorkflowId request).unWorkflowId)
              case report of
                Just details -> do
                  length details.calls @?= 1
                  details.complete @?= True
                Nothing -> assertFailure "actual-attempt report missing"
            server.requests >>= (\calls -> length calls @?= 1),
      testCase "pending judgment refuses an unavailable pinned model before dispatch" $
        withTypeSafeFixture 200 0 fixtureResponse \server ->
          withShikigamiFreshDatabase fixture \connection ->
            withStore (defaultConnectionSettings connection) \store -> do
              declaration <- mustRight <$> loadAgent "../agents/proof/shikumi-judgment-example.dhall"
              tracer <- noopTracer
              behavior <- newBehaviorEnv
              let request = (Fixture.routerJob "typesafe-pending-binding") {agentName = declaration.name, identity = compatibilityIdentity declaration.name, triggerPayload = toJSON fixtureTicket, lineage = [declaration.name]}
                  app = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}
                  selected = Decision.defaultDecisionServices (fixtureCatalog server.endpoint)
                  deps = (Fixture.routerDeps app behavior (Routing.RoutingRuntime (\_ -> pure Fixture.catalog) (\_ _ _ -> error "no routing")) [declaration]) {Agent.decisions = selected, Agent.deliveryPool = Just store.pool}
                  crash = Agent.defaultAgentRunHooks & #beforeStepBody .~ (\(StepName name) -> when (name == "decision-result-judge") (ioError (userError "stop before judgment")))
              _ <- try @SomeException (Agent.runAgentRunWorkflow (deps {Agent.hooks = crash}) request)
              server.requests >>= (@?= [])
              let unavailable = selected {Decision.catalog = mustRight (modelCatalog [])}
              outcome <- Agent.runAgentRunWorkflow (deps {Agent.decisions = unavailable}) request
              assertBool "pending model cannot rebind or dispatch" (case outcome of Right (Completed (Right _)) -> False; _ -> True)
              server.requests >>= (@?= [])
    ]

readOutcome :: AppEnv -> RunJob -> IO DecisionOutcome
readOutcome app request = do
  index <- either (assertFailure . show) pure =<< runAppIO app (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId request) 0)
  case Map.lookup "decision-result-judge" index of
    Just value -> case fromJSON value of Success outcome -> pure outcome; Error _ -> assertFailure "invalid structured outcome codec"
    Nothing -> assertFailure "committed judgment step missing"
