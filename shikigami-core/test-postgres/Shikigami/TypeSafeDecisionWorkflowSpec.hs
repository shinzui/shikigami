module Shikigami.TypeSafeDecisionWorkflowSpec (tests, qualifyInstalled) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, throwIO, try)
import Control.Lens ((&), (.~))
import Control.Monad (void, when)
import Data.Aeson (Result (..), encode, fromJSON, object, toJSON, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (liftIO)
import Keiro.PGMQ qualified as Job
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), defaultWorkflowRunOptions, loadStepIndex, runWorkflowWith, step)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), runJobWorkflowId)
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
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase, withShikigamiMigratedDatabase)
import Shikigami.Program.Decision
import Shikigami.Program.Decision.JudgmentExample
import Shikigami.Program.DecisionRunner
import Shikigami.RouterWorkflowSpec qualified as Fixture
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Trigger.Enqueue qualified as Enqueue
import Shikigami.Trigger.RequestKey qualified as RequestKey
import Shikumi.Decision.Setting (DecisionSetting (..))
import Shikumi.Program (emptyParams, setDecisionSetting)
import Shikumi.Stream qualified as SS
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (isAbsolute, (</>))
import System.IO (IOMode (WriteMode), hClose, openTempFile, withFile)
import System.Process qualified as Process
import System.Timeout (timeout)
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
      testCase "a public judgment stream acknowledges PostgreSQL evidence before completion and replays its stored outcome" $
        withTypeSafeFixture 200 0 fixtureResponse \server ->
          withShikigamiFreshDatabase fixture \connection -> do
            tracer <- noopTracer
            let app = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}
                name = WorkflowName "test.shikigami-judgment-stream"
                catalog = fixtureCatalog server.endpoint
                prepared = fixturePrepared catalog
                workflow = prepared.workflowId
                readReport store = do
                  report <- either (assertFailure . show) pure =<< readDecisionReport (postgresDecisionEvidenceStore store.pool) prepared.runId
                  case report of
                    Just details -> do
                      length details.calls @?= 1
                      details.complete @?= True
                      pure details
                    Nothing -> assertFailure "stream attempt report missing"
            original <- withStore (defaultConnectionSettings connection) \store -> do
              runtime <- fixtureRuntime catalog (decisionCallHooks (postgresDecisionEvidenceStore store.pool) Nothing)
              let observe = \case
                    SS.StreamStatus status | status.phase == SS.LmEnd -> readReport store >> pure ()
                    _ -> pure ()
                  body = step (StepName "judgment") do
                    (result, answers) <- liftIO (streamDecisionProgramWithAnswers runtime prepared (programRef judgmentProgram) fixtureTicket observe)
                    calls <- liftIO (readReport store)
                    pure (decisionOutcome prepared.identity prepared.program (toJSON <$> result) (map (.callId) calls.calls) answers)
              outcome <- runAppIO app (runWorkflowWith defaultWorkflowRunOptions name workflow body)
              case outcome of
                Right (Completed result) -> do
                  assertBool "typed result succeeds" (case result.result of Right _ -> True; Left _ -> False)
                  length (outcomeAnswers result) @?= 1
                  pure result
                _ -> assertFailure "streamed workflow did not complete"
            restored <- runAppIO app (runWorkflowWith defaultWorkflowRunOptions name workflow (step (StepName "judgment") (liftIO (ioError (userError "committed stream redispatched")))))
            restored @?= Right (Completed original)
            withStore (defaultConnectionSettings connection) \store -> do
              _ <- readReport store
              pure ()
            server.requests >>= (\requests -> length requests @?= 1),
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

-- Explicit acceptance mode; the ordinary suite never silently substitutes
-- checkout commands for the immutable operator, worker or proof-agent assets.
qualifyInstalled :: FilePath -> FilePath -> FilePath -> IO ()
qualifyInstalled operator worker agents = do
  assertBool "installed paths must be absolute" (all isAbsolute [operator, worker, agents])
  withTypeSafeFixture 200 0 fixtureResponse \server ->
    withShikigamiMigratedDatabase \connection ->
      bracket scratch removeDirectoryRecursive \directory -> do
        declaration <- mustRight <$> loadAgent (agents </> "shikumi-judgment-example.dhall")
        ambient <- getEnvironment
        let environment = ("OTEL_SDK_DISABLED", "true") : filter (\(key, _) -> not ("SHIKIGAMI_" `Text.isPrefixOf` Text.pack key) && key `notElem` ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CODEX_API_KEY", "TYPESAFE_API_KEY", "OTEL_SDK_DISABLED"]) ambient
            configuration = directory </> "fixture.json"
            decisionModels = [object ["alias" .= ("judge" :: Text.Text), "version" .= ("1" :: Text.Text), "bindingId" .= ("installed-fixture" :: Text.Text), "bindingVersion" .= ("1" :: Text.Text), "provider" .= ("typesafe" :: Text.Text), "model" .= ("jev-latest" :: Text.Text), "thinking" .= ("default" :: Text.Text), "base_url" .= server.endpoint]]
            run executable args = do
              outcome <- timeout 30000000 (Process.readCreateProcessWithExitCode ((Process.proc executable args) {Process.cwd = Just directory, Process.env = Just environment}) "")
              case outcome of
                Just (ExitSuccess, output, _) -> pure output
                other -> assertFailure ("installed command failed: " <> show other)
            requestKey = mustRight (RequestKey.parseRequestKey "ep80-installed")
            request = (Fixture.routerJob "installed-judgment") {agentName = declaration.name, idempotencyKey = Enqueue.addressedRunKeyWithKey declaration.name AgentWorkflowRoute requestKey}
        LBS.writeFile configuration (encode (object ["database" .= object ["connection_string" .= connection], "agents" .= object ["directory" .= agents, "strict" .= True], "behavior" .= object ["provider" .= ("stub" :: Text.Text), "decisionModels" .= decisionModels], "credentials" .= object ["providers" .= object ["typesafe" .= object ["api_key" .= ("public-fixture-key" :: Text.Text)]]]]))
        void (run operator ["--config", configuration, "--check-config"])
        server.requests >>= (@?= [])
        void (run operator ["--config", configuration, "enqueue-run", "shikumi-judgment-example", "--payload", "{\"ticket\":\"Checkout is unavailable.\"}", "--key", "ep80-installed"])
        tracer <- noopTracer
        let app = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}
            waitRecorded = do
              index <- either (assertFailure . show) pure =<< runAppIO app (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId request) 0)
              if Map.member "record" index then readOutcome app request else threadDelay 100000 >> waitRecorded
        withFile (directory </> "worker.log") WriteMode \logHandle -> do
          let process = (Process.proc worker ["--config", configuration]) {Process.cwd = Just directory, Process.env = Just environment, Process.std_out = Process.UseHandle logHandle, Process.std_err = Process.UseHandle logHandle}
              stop (_, _, _, handle) = do
                Process.terminateProcess handle
                stopped <- timeout 10000000 (Process.waitForProcess handle)
                case stopped of Nothing -> assertFailure "installed worker did not stop"; Just _ -> pure ()
          original <- bracket (Process.createProcess process) stop \_ -> do
            result <- timeout 30000000 waitRecorded
            maybe (assertFailure "installed worker did not record judgment") pure result
          length (outcomeAnswers original) @?= 1
          length original.attempts @?= 1
          case original.result of Right _ -> pure (); Left failure -> assertFailure (show failure)
          restored <- bracket (Process.createProcess process) stop \_ -> do
            void (run operator ["--config", configuration, "enqueue-run", "shikumi-judgment-example", "--payload", "{\"ticket\":\"Checkout is unavailable.\"}", "--key", "ep80-installed"])
            threadDelay 1000000
            readOutcome app request
          toJSON restored @?= toJSON original
        server.requests >>= (\requests -> length requests @?= 1)
        putStrLn "installed judgment: config, enqueue, worker, restart and one total HTTP call passed"
  where
    scratch = do
      temporary <- getTemporaryDirectory
      (path, handle) <- openTempFile temporary "shikigami-installed-judgment"
      hClose handle
      removeFile path
      createDirectory path
      pure path
