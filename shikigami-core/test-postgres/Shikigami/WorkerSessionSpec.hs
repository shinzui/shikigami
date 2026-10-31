module Shikigami.WorkerSessionSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Time (addUTCTime)
import Effectful (Eff)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowOutcome (Completed, ContinuedAsNew, Suspended), currentGeneration, loadStepIndex, runWorkflowWith)
import Keiro.Workflow.Awakeable (awakeableNamed)
import Keiro.Workflow.Child (runChildWorkflow, spawnChild)
import Keiro.Workflow.Gc (WorkflowGcPolicy (..), gcWorkflowsOnce)
import Kioku.Id (genSessionId)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.RunFailure (AgentRunFailure)
import Shikigami.Agent.RunJob (RunJob (..))
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Behavior.Run (newBehaviorEnv)
import Shikigami.Delegation.BudgetStore (delegationBudgetIdFor, reserveEnrolledDelegationSlots)
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Execution.Identity qualified as Identity
import Shikigami.Execution.Quantity (ResourceAmount, parseResourceAmount)
import Shikigami.Execution.Request (ExecutionRequest (..))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude hiding ((.=))
import Shikigami.RouterWorkflowSpec qualified as Fixture
import Shikigami.StateRevision (StateRevision, parseRevision)
import Shikigami.WorkerSession.Checkpoint qualified as Checkpoint
import Shikigami.WorkerSession.Identity
import Shikigami.WorkerSession.Input (InstructionText, parseInstructionText)
import Shikigami.WorkerSession.Integration qualified as Integration
import Shikigami.WorkerSession.Store qualified as Store
import Shikigami.WorkerSession.Types
import Shikigami.WorkerSession.Workflow qualified as Session
import Shikigami.WorkerSessionStoreSpec (checkpointVersion, fixtureCheckpoints, withFixture)
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "WorkerSession"
    [ testCase "two governed assignments survive idle rotation with retained findings and distinct children" $
        withFixture fixture \env admission access -> do
          version <- checkpointVersion admission
          (provider, _) <- fixtureCheckpoints version False
          let runtime = Session.SessionRuntime env [admission.delegator & #name .~ "worker" & #delegates .~ []] disabledDirectoryHandle (const (pure (Right ()))) (Just provider)
              session = sessionIdFor admission
              options = shikigamiWorkflowRunOptions env
              drive initial = run env (runWorkflowWith options sessionWorkflowName (sessionWorkflowId session) (Session.sessionWorkflow runtime initial))
              inspect = do Just (state, _) <- expectRight =<< run env (Store.inspectSession session); pure state
              input text = Instruction 1 FollowUp (fixtureInstruction text) (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) (Just (ExecutionRequest (Just "worker-model") (Just ["worker-model"]) Nothing))
          (_, first) <- expectRight =<< run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (OperationId "first") (input "first"))
          drive (Just (Session.WorkerSessionStart session)) >>= (@?= Suspended)
          started <- expectRight =<< run env (Store.readAssignment access first.assignmentId)
          child <- maybe (assertFailure "missing child" >> fail "missing child") (pure . WorkflowId) started.childWorkflowId
          job <- childJob env child
          job.executionRequest @?= (input "first").selection
          job.executionPermissions @?= admission.context.executionPermissions
          job.executionRootId @?= admission.context.executionRootId
          callbacks <- newIORef (0 :: Int)
          completeFixtureChild env child callbacks (Aeson.object ["finding" .= ("retained-first" :: Text)])
          drive Nothing >>= (@?= ContinuedAsNew)
          drive Nothing >>= (@?= Suspended)
          idle <- inspect
          idle.phase @?= Idle
          (_, second) <- expectRight =<< run env (Store.acceptMessage access idle.revision (fixtureRevision 0) (OperationId "second") (input "second"))
          drive Nothing >>= (@?= ContinuedAsNew)
          drive Nothing >>= (@?= Suspended)
          secondStarted <- expectRight =<< run env (Store.readAssignment access second.assignmentId)
          assertBool "different assignment children" (started.childWorkflowId /= secondStarted.childWorkflowId)
          context <- expectRight =<< run env (Store.readAssignmentContext access second.assignmentId)
          map (\finding -> finding.receipt.assignmentId) context @?= [first.assignmentId]
          map (.output) context @?= [Just (Aeson.object ["finding" .= ("retained-first" :: Text)])]
          secondChild <- maybe (assertFailure "missing second child" >> fail "missing child") (pure . WorkflowId) secondStarted.childWorkflowId
          secondJob <- childJob env secondChild
          assertBool "the actual child receives retained context" ("retained-first" `isInfixOf` show (Aeson.encode secondJob.triggerPayload))
          drive Nothing >>= (@?= Suspended)
          completeFixtureChild env secondChild callbacks (Aeson.object ["finding" .= ("second" :: Text)])
          drive Nothing >>= (@?= ContinuedAsNew)
          drive Nothing >>= (@?= Suspended)
          readIORef callbacks >>= (@?= 2)
          run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (OperationId "first") (input "first")) >>= (@?= Right (Resources.AlreadyAccepted, first))
          generation <- run env (currentGeneration sessionWorkflowName (sessionWorkflowId session))
          drive Nothing >>= (@?= Suspended)
          run env (currentGeneration sessionWorkflowName (sessionWorkflowId session)) >>= (@?= generation)
          events <- expectRight =<< run env (Store.readEvents access (fixtureRevision 0) 100)
          length [() | EventReceipt {event = ResultAvailable {}} <- events] @?= 2
          root <- maybe (assertFailure "missing root" >> fail "missing root") pure admission.context.executionRootId
          ledger <- expectRight =<< run env (Roots.inspectRoot root)
          Map.lookup Resources.LifetimeDescendants ledger.usage.settled @?= Just (fixtureAmount 2),
      testCase "a registered child with missing input is repaired through governed delegation without another reservation" $
        withFixture fixture \env admission access -> do
          version <- checkpointVersion admission
          (provider, _) <- fixtureCheckpoints version False
          behavior <- newBehaviorEnv
          let worker = Fixture.successSpecialist "worker"
              runtime = Session.SessionRuntime env [worker] disabledDirectoryHandle (const (pure (Right ()))) (Just provider)
              session = sessionIdFor admission
              parentId = sessionWorkflowId session
              options = shikigamiWorkflowRunOptions env
              dependencies = Fixture.routerDeps env behavior (Routing.RoutingRuntime (\_ -> fail "unexpected routing") (\_ _ _ -> fail "unexpected routing")) [worker]
          (_, message) <- expectRight =<< run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (OperationId "send") (Instruction 1 FollowUp (fixtureInstruction "recover input") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing))
          (_, started) <- expectRight =<< run env (Store.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (OperationId "start") message.assignmentId)
          child <- maybe (assertFailure "missing mapping" >> fail "missing mapping") (pure . WorkflowId) started.childWorkflowId
          root <- maybe (assertFailure "missing root" >> fail "missing root") pure admission.context.executionRootId
          now <- getCurrentTime
          _ <- expectRight =<< run env (reserveEnrolledDelegationSlots root (delegationBudgetIdFor parentId) (Just (parentId, admission.context.budgetLimit)) (child :| []) now)
          let crashWindow = do
                _ <- spawnChild agentRunWorkflowName child (pure ())
                (_, wait) <- awakeableNamed (StepName "fixture-crash-window")
                wait :: Eff (Workflow : AppEffects) ()
          run env (runWorkflowWith options sessionWorkflowName parentId crashWindow) >>= (@?= Suspended)
          run env (loadStepIndex agentRunWorkflowName child 0) >>= (@?= Map.empty)
          let drive = run env (runWorkflowWith options sessionWorkflowName parentId (Session.sessionWorkflow runtime (Just (Session.WorkerSessionStart session))))
          drive >>= (@?= Suspended)
          job <- childJob env child
          job.identity @?= admission.identity
          job.executionRootId @?= admission.context.executionRootId
          result <- run env (runChildWorkflow options agentRunWorkflowName child (Agent.agentRunWorkflow dependencies Nothing))
          case result of Completed (Right _) -> pure (); _ -> assertFailure (show result)
          drive >>= (@?= ContinuedAsNew)
          stored <- expectRight =<< run env (Store.readResult access message.assignmentId)
          case stored of Just (_, value) -> value.disposition @?= AssignmentSucceeded; _ -> assertFailure "result lost"
          ledger <- expectRight =<< run env (Roots.inspectRoot root)
          Map.lookup Resources.LifetimeDescendants ledger.usage.settled @?= Just (fixtureAmount 1),
      testCase "a pre-spawn root refusal becomes one retained failure and creates no child" $
        withFixture fixture \env admission _ -> do
          now <- getCurrentTime
          let root = Identity.ExecutionRootId "exhausted-session-root"
              limited = admission & #scope . #parent .~ "limited-coordinator" & #objective . #key .~ "limited-objective" & #context . #executionRootId .~ Just root
          _ <- expectRight =<< run env (Roots.enrollRoot root (Resources.Envelope (Map.singleton Resources.LifetimeDescendants (Resources.Limited (fixtureAmount 0))) (addUTCTime 3600 now)))
          _ <- expectRight =<< run env (Store.openSession limited)
          access <- expectRight =<< run env (Store.authorizeSession (sessionIdFor limited) limited.context.identity (pure (Right ())))
          (_, message) <- expectRight =<< run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (OperationId "send") (Instruction 1 FollowUp (fixtureInstruction "no capacity") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing))
          version <- checkpointVersion limited
          (provider, _) <- fixtureCheckpoints version False
          let runtime = Session.SessionRuntime env [Fixture.successSpecialist "worker"] disabledDirectoryHandle (const (pure (Right ()))) (Just provider)
          run env (runWorkflowWith (shikigamiWorkflowRunOptions env) sessionWorkflowName (sessionWorkflowId (sessionIdFor limited)) (Session.sessionWorkflow runtime (Just (Session.WorkerSessionStart (sessionIdFor limited))))) >>= (@?= ContinuedAsNew)
          stored <- expectRight =<< run env (Store.readResult access message.assignmentId)
          case stored of Just (_, value) -> value.disposition @?= AssignmentFailed; _ -> assertFailure "refusal not retained"
          let child = assignmentChildWorkflowId (sessionIdFor limited) limited.worker message.assignmentId
          run env (loadStepIndex agentRunWorkflowName child 0) >>= (@?= Map.empty),
      testCase "closed retained events remain acknowledgeable after session journal GC" $
        withFixture fixture \env admission access -> do
          version <- checkpointVersion admission
          (provider, _) <- fixtureCheckpoints version False
          let runtime = Session.SessionRuntime env [] disabledDirectoryHandle (const (pure (Right ()))) (Just provider)
              session = sessionIdFor admission
              drive = run env (runWorkflowWith (shikigamiWorkflowRunOptions env) sessionWorkflowName (sessionWorkflowId session) (Session.sessionWorkflow runtime (Just (Session.WorkerSessionStart session))))
          drive >>= (@?= Suspended)
          _ <- expectRight =<< run env (Store.closeSession access (fixtureRevision 1) (fixtureRevision 0) (OperationId "close") AssignmentCancelled)
          drive >>= (@?= ContinuedAsNew)
          result <- drive
          case result of Completed _ -> pure (); _ -> assertFailure (show result)
          now <- getCurrentTime
          _ <- run env (gcWorkflowsOnce (addUTCTime 1 now) (WorkflowGcPolicy 0 10))
          run env (Store.consumeEventsWith access (fixtureRevision 2) (fixtureRevision 0) (OperationId "final-ack") (fixtureRevision 0) (fixtureRevision 1) (pure (Right ()))) >>= (@?= Right (Resources.Accepted, fixtureRevision 1)),
      testCase "checkpoint runtime retries an accepted unknown request before preparing another batch" $
        withFixture fixture \env admission access -> do
          _ <- expectRight =<< run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (OperationId "first") (Instruction 1 FollowUp (fixtureInstruction "first") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing))
          version <- checkpointVersion admission
          (provider, count) <- fixtureCheckpoints version True
          let runtime = Session.SessionRuntime env [] disabledDirectoryHandle (const (pure (Right ()))) (Just provider)
              integrate = run env (Integration.integrateEvents runtime (sessionIdFor admission) (OperationId "checkpoint"))
          integrate >>= (@?= Right Integration.EventsPending)
          integrated <- expectRight =<< integrate
          case integrated of Integration.EventsIntegrated _ cursor | cursor == fixtureRevision 1 -> pure (); _ -> assertFailure (show integrated)
          integrate >>= (@?= Right integrated)
          count >>= (@?= 1)
          run env (Integration.integrateEvents runtime (sessionIdFor admission) (OperationId "next-batch")) >>= (@?= Right (Integration.EventsCaughtUp (fixtureRevision 1))),
      testCase "missing or stale objective authority admits no child or descendant reservation" $
        withFixture fixture \env admission access -> do
          (_, message) <- expectRight =<< run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (OperationId "first") (Instruction 1 FollowUp (fixtureInstruction "first") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing))
          version <- checkpointVersion admission
          let provider = Checkpoint.CheckpointProvider (\_ -> pure (Right (version & #ownerEpoch .~ (fixtureRevision 99)))) (\_ -> fail "denied checkpoint callback")
              unavailable = Session.SessionRuntime env [] disabledDirectoryHandle (const (pure (Right ()))) Nothing
          run env (Session.selectAssignment unavailable (sessionIdFor admission)) >>= (@?= Right Session.SessionBlocked)
          run env (Session.selectAssignment (unavailable & #checkpoints .~ Just provider) (sessionIdFor admission)) >>= (@?= Right Session.SessionBlocked)
          stored <- expectRight =<< run env (Store.readAssignment access message.assignmentId)
          stored.phase @?= Queued
          stored.childWorkflowId @?= Nothing
          root <- maybe (assertFailure "missing root" >> fail "missing root") pure admission.context.executionRootId
          ledger <- expectRight =<< run env (Roots.inspectRoot root)
          Map.lookup Resources.LifetimeDescendants ledger.usage.settled @?= Nothing
    ]

childJob :: AppEnv -> WorkflowId -> IO RunJob
childJob env child = do
  entries <- run env (loadStepIndex agentRunWorkflowName child 0)
  value <- maybe (assertFailure "missing governed child ingestion" >> fail "missing ingestion") pure (Map.lookup "ingest-job" entries)
  case Aeson.fromJSON value of Aeson.Success job -> pure job; Aeson.Error err -> assertFailure err >> fail err

-- The fixture executes a registered child through Keiro's real completion
-- boundary. It does not stand in for an IR-11 or IR-13 production provider.
completeFixtureChild :: AppEnv -> WorkflowId -> IORef Int -> Aeson.Value -> IO ()
completeFixtureChild env child calls output = do
  memory <- genSessionId
  let body :: Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult)
      body = liftIO (modifyIORef' calls (+ 1)) >> pure (Right (AgentRunResult memory [] output Nothing))
  outcome <- run env (runChildWorkflow (shikigamiWorkflowRunOptions env) agentRunWorkflowName child body)
  case outcome of Completed _ -> pure (); _ -> assertFailure "fixture child did not complete"

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= either (assertFailure . show) pure

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> fail (show err)) pure

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureAmount :: Integer -> ResourceAmount
fixtureAmount amount = either (error . show) id (parseResourceAmount amount)

fixtureInstruction :: Text -> InstructionText
fixtureInstruction value = either (error . show) id (parseInstructionText value)
