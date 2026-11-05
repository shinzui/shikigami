{-# LANGUAGE DataKinds #-}

module Shikigami.DecisionExecutionSpec (tests) where

import Baikai.Options (emptyOptions)
import Baikai.Provider.Registry (ApiProvider (..), newProviderRegistryFrom)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Monad (void)
import Data.Aeson (toJSON)
import Data.Aeson qualified
import Data.Generics.Labels ()
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time (addUTCTime, getCurrentTime)
import Keiro.Timer qualified as Timer
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), runWorkflow, step)
import Keiro.Workflow.Child (runChildWorkflow)
import Kiroku.Store.Connection (KirokuStore (..), withStore)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.App (AppEnv (..))
import Shikigami.Attestation.PolicyValue (mkCeiling)
import Shikigami.Behavior.Run (BehaviorEnv (..))
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Decision.Accounting (boundDecisionTimeout)
import Shikigami.Decision.Contract
import Shikigami.Decision.Evidence
import Shikigami.Decision.Execution
import Shikigami.Decision.ModelCatalog
import Shikigami.Decision.StubProvider (decisionStubProvider)
import Shikigami.Execution.AssignmentKey (assignmentIdFor)
import Shikigami.Execution.Capacity qualified as Capacity
import Shikigami.Execution.Counter qualified
import Shikigami.Execution.Driver qualified as Driver
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Quantity (amountUnits)
import Shikigami.Execution.Quantity qualified
import Shikigami.Execution.Request (ExecutionPolicy (..))
import Shikigami.Execution.Resources qualified as R
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Selection
import Shikigami.Execution.SelectionRuntime (SelectionRuntime (..))
import Shikigami.Execution.Start qualified as Start
import Shikigami.Execution.Store qualified as Store
import Shikigami.Execution.Timer (observationFireAction)
import Shikigami.Execution.Transcript
import Shikigami.ExecutionDriver.Generated.WorkflowRuntime qualified as Generated
import Shikigami.ExecutionTranscriptSpec (driverRuntime, pendingReference, pumpDriver, run, withConfiguredResourceFixture)
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude ((&), (.~))
import Shikigami.Program.Decision
import Shikigami.Program.Decision.Examples
import Shikigami.Program.DecisionRunner
import Shikigami.Program.Runtime (ProgramRuntime (..))
import Shikigami.RouterWorkflowSpec qualified as Fixture
import Shikigami.Trigger.Enqueue (ensureRunQueue)
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "DecisionExecution"
    [ testCase "retained decision limits narrow a later runtime and actual options obey the absolute cutoff" $
        withDecision fixture id $ \env snapshot executor runtime evidence prepared load count _ -> do
          now <- getCurrentTime
          let limits = DecisionWorkLimits (rightPure (parseDecisionTimeout 1000000)) (rightPure (mkCeiling 1))
          boundDecisionTimeout runtime.timeoutMicros (Just (addUTCTime 0.01 now)) now @?= Right (rightPure (parseDecisionTimeout 10000))
          either (\err -> failureCode err @?= CallLimitExceeded) (const (assertFailure "expired cutoff admitted")) (boundDecisionTimeout runtime.timeoutMicros (Just now) now)
          start <- right =<< admitBoundedDecisionExecution limits executor snapshot.identity prepared load
          prepare env executor start
          reference <- pendingReference env snapshot
          Executor.executeAcceptedAttemptWithDecision (executeDecisionWork evidence (const runtime)) executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          result <- pumpDriver env executor snapshot 5
          outcome <- decode =<< right =<< Start.readExecutionResult executor snapshot.identity result
          either (\err -> failureCode err @?= CallLimitExceeded) (const (assertFailure "retained actual-call limit expanded")) outcome.result
          readIORef count >>= (@?= 1),
      testCase "a retained short timeout releases runtime occupancy and keeps actual root spending unknown" $
        withDecision fixture id $ \env snapshot executor runtime evidence prepared load _ _ -> do
          let limits = DecisionWorkLimits (rightPure (parseDecisionTimeout 50000)) (rightPure (mkCeiling 64))
              delayed provider = provider & #complete .~ (\model context options -> threadDelay 1000000 >> provider.complete model context options)
              later = runtime & #providers .~ map delayed runtime.providers
          start <- right =<< admitBoundedDecisionExecution limits executor snapshot.identity prepared load
          prepare env executor start
          reference <- pendingReference env snapshot
          Executor.executeAcceptedAttemptWithDecision (executeDecisionWork evidence (const later)) executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          native <- right =<< run env (Store.inspectExecution snapshot.executionId)
          maybe (assertFailure "missing typed execution") (\(state, _, _) -> state.phase @?= Unresolved) native
          cap <- right =<< run env (runTransaction Capacity.inspectTx)
          cap.active @?= 0
          root <- right =<< run env (Roots.inspectRoot (maybe (error "root") id snapshot.selection.rootId))
          Shikigami.Execution.Counter.attemptNumber root.active @?= 1
          Shikigami.Execution.Counter.attemptNumber root.unknown @?= 1,
      testCase "two internal calls settle the shared root; restart reuses accepted work and committed result" $
        withDecision fixture id $ \env snapshot executor runtime evidence prepared load count _ -> do
          start <- right =<< admitDecisionExecution executor snapshot.identity prepared load
          -- A crash after acceptance must not consult live registration/catalog.
          admitDecisionExecution executor snapshot.identity prepared (assertFailure "accepted work invoked its live loader") >>= (@?= Right start)
          prepare env executor start
          reference <- pendingReference env snapshot
          Executor.executeAcceptedAttemptWithDecision (executeDecisionWork evidence (const runtime)) executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          result <- pumpDriver env executor snapshot 5
          value <- right =<< Start.readExecutionResult executor snapshot.identity result
          outcome <- decode value
          outcome.preparationId @?= prepared.identity
          length outcome.attempts @?= 2
          readIORef count >>= (@?= 2)
          -- Redelivery observes the accepted terminal; the runner is unreachable.
          Executor.executeAcceptedAttemptWithDecision (\_ _ _ -> assertFailure "committed decision ran again") executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          root <- right =<< run env (Roots.inspectRoot (maybe (error "root") id snapshot.selection.rootId))
          fmap amountUnits (Map.lookup R.ModelAttempts root.usage.settled) @?= Just 2
          report <- right =<< readDecisionReport evidence prepared.runId
          maybe (assertFailure "evidence missing") (\retained -> length retained.calls @?= 2) report,
      testCase "a real typed Flow slot suspends; held decision and worker share capacity while timers and unrelated advances progress" $
        withDecision fixture id $ \env template executor runtime evidence _ _ count workerSnapshot -> do
          cap <- right =<< run env (runTransaction Capacity.inspectTx)
          run env (runTransaction (Capacity.reconfigureTx cap.revision (rightPure (Capacity.parseCapacityLimit 2)))) >>= (@?= Right ())
          pinned <- newIORef Nothing
          entered <- newEmptyMVar
          release <- newEmptyMVar
          intervals <- newIORef []
          let alias = template.selection.descriptor.alias
              slot = Decision.decisionSlot (Decision.decisionStep Decision.Adaptive (programRef investigationProgram)) [alias]
              declaration = Fixture.routerDecl & #decisionModels .~ [alias]
              policy = rightPure (resolvePolicy runtime.programs [slot] runtime.catalog declaration Nothing)
              metadata prepared = template & #executionId .~ decisionExecutionId prepared & #runId .~ prepared.workflowId & #selection . #assignmentId .~ assignmentIdFor ("typed-decision:" <> decisionPreparationIdText prepared.identity)
              host =
                Decision.AcceptedDecisionHost
                  executor
                  template.identity
                  ( \prepared parameters -> do
                      writeIORef pinned (Just prepared)
                      admitDecisionExecution
                        executor
                        template.identity
                        prepared
                        ( do
                            state <- parameters
                            pure (Right (metadata prepared, state))
                        )
                  )
              decisionEnv = Decision.DecisionEnv declaration [slot] (Decision.defaultDecisionServices runtime.catalog) runtime.runtime Nothing evidence (Routing.RoutingRuntime (\_ -> error "unused routing catalog") (\_ _ _ -> error "unused routing evaluation")) runtime.timeoutMicros Nothing (const (pure ())) (const (pure ()))
              parent = runWorkflow (WorkflowName "accepted-decision-slot") template.runId (Decision.runDecisionAccepted decisionEnv host policy (Decision.decide (Decision.decisionStep Decision.Adaptive (programRef investigationProgram)) alias (InvestigationInput "build" "early finding" "bounded catalog")))
              hold provider =
                provider
                  & #complete
                  .~ ( \model context options -> do
                         begin <- getCurrentTime
                         putMVar entered ()
                         readMVar release
                         result <- provider.complete model context options
                         end <- getCurrentTime
                         atomicModifyIORef' intervals (\previous -> ((begin, end) : previous, ()))
                         pure result
                     )
              decisionRuntime = runtime & #providers .~ map hold runtime.providers
          run env parent >>= (@?= Suspended)
          readIORef count >>= (@?= 0)
          prepared <- readIORef pinned >>= maybe (assertFailure "slot did not retain its preparation") pure
          let snapshot = metadata prepared
              start = Driver.ExecutionStart snapshot.executionId
          -- Independent accepted worker execution retains its original selection.
          -- Its real provider is held by the same bounded barrier.
          let selected = executor.selectionRuntime template
              heldProviders = map hold selected.providers
          heldRegistry <- newProviderRegistryFrom heldProviders
          let workerExecutor = executor {Executor.selectionRuntime = const (selected {providers = heldProviders, baseEnv = selected.baseEnv & #providerRegistry .~ Just heldRegistry})}
          prepare env executor start
          -- Template is already an admitted execution from the root fixture.
          prepare env workerExecutor (Driver.ExecutionStart workerSnapshot.executionId)
          decisionRef <- pendingReference env snapshot
          workerRef <- pendingReference env workerSnapshot
          withAsync (Executor.executeAcceptedAttemptWithDecision (executeDecisionWork evidence (const decisionRuntime)) executor snapshot.identity decisionRef) $ \decisionTask -> do
            timeout 2000000 (takeMVar entered) >>= maybe (assertFailure "decision did not enter") pure
            withAsync (Executor.executeAcceptedAttempt workerExecutor workerSnapshot.identity workerRef) $ \workerTask -> do
              timeout 2000000 (takeMVar entered) >>= maybe (assertFailure "worker did not enter") pure
              current <- right =<< run env (runTransaction Capacity.inspectTx)
              current.active @?= 2
              root <- right =<< run env (Roots.inspectRoot (maybe (error "root") id snapshot.selection.rootId))
              Shikigami.Execution.Counter.attemptNumber root.active @?= 2
              run env parent >>= (@?= Suspended)
              run env (runWorkflow (WorkflowName "unrelated-ready-root") (WorkflowId "ready-during-decision") (step (StepName "progress") (pure True))) >>= (@?= Completed True)
              now <- getCurrentTime
              timer <- run env (Timer.claimDueTimer (addUTCTime 120 now)) >>= maybe (assertFailure "due observation timer did not progress") pure
              fired <- run env (observationFireAction timer)
              assertBool "timer fired while providers held" (isJust fired)
              putMVar release ()
              wait decisionTask >>= (@?= Right Executor.ExecutorDone)
              -- The second internal call shares the released barrier.
              wait workerTask >>= (@?= Right Executor.ExecutorDone)
          observed <- sortOn fst <$> readIORef intervals
          case observed of
            ((aStart, aEnd) : (bStart, bEnd) : _) -> assertBool "actual decision and worker intervals overlap" (max aStart bStart < min aEnd bEnd)
            _ -> assertFailure "missing actual provider intervals"
          drained <- right =<< run env (runTransaction Capacity.inspectTx)
          drained.active @?= 0
          completeChild env executor start
          final <- run env parent
          case final of Completed _ -> pure (); _ -> assertFailure (show final)
          readIORef count >>= (@?= 2)
          -- A committed parent result replays after implementations are retired.
          let retired = decisionEnv {Decision.services = decisionEnv.services & #programs .~ rightPure (programRegistry [])}
          replayed <- run env (runWorkflow (WorkflowName "accepted-decision-slot") template.runId (Decision.runDecisionAccepted retired host policy (Decision.decide (Decision.decisionStep Decision.Adaptive (programRef investigationProgram)) alias (InvestigationInput "changed input ignored by replay" "finding" "catalog"))))
          replayed @?= final,
      testCase "an internal second call cannot escape the root attempt limit" $
        withDecision fixture (Map.insert R.ModelAttempts (R.Limited (rightPure (Shikigami.Execution.Quantity.parseResourceAmount 1)))) $ \env snapshot executor runtime evidence prepared load count _ -> do
          start <- right =<< admitDecisionExecution executor snapshot.identity prepared load
          prepare env executor start
          reference <- pendingReference env snapshot
          Executor.executeAcceptedAttemptWithDecision (executeDecisionWork evidence (const runtime)) executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          result <- pumpDriver env executor snapshot 5
          outcome <- decode =<< right =<< Start.readExecutionResult executor snapshot.identity result
          either (\err -> failureCode err @?= CallLimitExceeded) (const (assertFailure "root-exhausted program succeeded")) outcome.result
          readIORef count >>= (@?= 1)
    ]

withDecision :: DatabaseFixture -> (R.Limits -> R.Limits) -> (AppEnv -> ExecutionSnapshot -> Executor.ExecutionRuntime -> DecisionRuntime -> DecisionEvidenceStore -> PreparedDecision -> IO (Either ExecutionError (ExecutionSnapshot, Data.Aeson.Value)) -> IORef Int -> ExecutionSnapshot -> IO a) -> IO a
withDecision fixture limits use = withConfiguredResourceFixture fixture id (limits . Map.insert R.Tokens R.ExplicitlyUnbounded) $ \original template _ ->
  withStore original.connectionSettings $ \store -> do
    let env = original & #store .~ Just store
    ensureRunQueue store.pool >>= right
    (executor, _, _) <- driverRuntime env False
    count <- newIORef (0 :: Int)
    let alias = rightPure (parseModelAlias "adaptive")
        binding = rightPure (modelBinding alias "1" "decision-fixture" "1" (stubModel & #modelId .~ "stub-investigate") emptyOptions Nothing)
        catalog = rightPure (modelCatalog [binding])
        prepared = PreparedDecision (decisionPreparationId (toJSON ("accepted-decision" :: Text))) (runCorrelationId template.runId.unWorkflowId) template.runId initialDecisionGeneration investigationDecisionSlot (descriptor (programRef investigationProgram)) (toJSON (InvestigationInput "build" "finding" "bounded catalog")) (modelDescriptor binding) Nothing
    now <- getCurrentTime
    let assignment = assignmentIdFor ("typed-decision:" <> decisionPreparationIdText prepared.identity)
        selection = rightPure (resolveExecutionSelection assignment catalog (Left ExecutionAliasUnavailable) (Just (ExecutionPolicy alias [alias])) Nothing Nothing Nothing template.selection.rootId now)
        snapshot = template & #executionId .~ decisionExecutionId prepared & #selection .~ selection
        evidence = postgresDecisionEvidenceStore store.pool
        base = executor.selectionRuntime snapshot
        provider = decisionStubProvider & #complete .~ (\model context options -> modifyIORef' count (+ 1) >> decisionStubProvider.complete model context options)
        runtime = DecisionRuntime base.baseEnv.runtime examplePrograms catalog Nothing (decisionCallHooks evidence Nothing) [provider] (rightPure (parseDecisionTimeout 3000000)) (rightPure (mkCeiling 64))
        load :: IO (Either ExecutionError (ExecutionSnapshot, Data.Aeson.Value))
        load = pure (Right (snapshot, registeredParameterState investigationProgram))
    use env snapshot executor runtime evidence prepared load count template

prepare :: AppEnv -> Executor.ExecutionRuntime -> Driver.ExecutionStart -> IO ()
prepare env executor start = go (4 :: Int)
  where
    go 0 = assertFailure "accepted driver failed to suspend"
    go remaining = do
      outcome <- run env (runWorkflow Generated.workflowName (executionWorkflowId start.executionId) (Driver.executionWorkflow executor (Just start)))
      case outcome of ContinuedAsNew -> go (remaining - 1); Suspended -> pure (); _ -> assertFailure (show outcome)

decode :: Data.Aeson.Value -> IO DecisionOutcome
decode value = case Data.Aeson.fromJSON value of Data.Aeson.Success outcome -> pure (outcome :: DecisionOutcome); Data.Aeson.Error err -> assertFailure err

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

rightPure :: (Show e) => Either e a -> a
rightPure = either (error . show) id

completeChild :: AppEnv -> Executor.ExecutionRuntime -> Driver.ExecutionStart -> IO ()
completeChild env executor start = go (6 :: Int)
  where
    go 0 = assertFailure "accepted child failed to complete"
    go remaining = do
      result <- run env (runChildWorkflow (shikigamiWorkflowRunOptions env) Generated.workflowName (executionWorkflowId start.executionId) (Driver.executionWorkflow executor (Just start)))
      case result of Completed _ -> pure (); ContinuedAsNew -> go (remaining - 1); other -> assertFailure (show other)
