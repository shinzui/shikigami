{-# LANGUAGE DataKinds #-}

module Shikigami.MandateTimerSpec (tests) where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Timer (TimerRow (..), TimerStatus (..), claimDueTimer, lookupTimer)
import Keiro.Timer qualified as Timer
import Keiro.Workflow (WorkflowOutcome (..), currentGeneration, runWorkflowWith)
import Keiro.Workflow.Resume (resumeWorkflowsOnce)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Connection qualified as Connection
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Execution.Coordinate (executionCoordinate)
import Shikigami.Execution.Quantity (ResourceAmount, parseResourceAmount)
import Shikigami.Execution.Resources qualified as R
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Fixture.ExecutionIdentity (fixtureAttemptId, fixtureOperationId, fixtureRootId)
import Shikigami.Log qualified as Log
import Shikigami.Mandate.Cycle qualified as Cycles
import Shikigami.Mandate.Store qualified as Mandates
import Shikigami.Mandate.Timer qualified as MandateTimer
import Shikigami.Mandate.Types qualified as M
import Shikigami.Mandate.Wake qualified as Wake
import Shikigami.Mandate.Workflow qualified as Workflow
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Objective.Capability qualified as Owner
import Shikigami.Objective.Command
import Shikigami.Objective.Runtime qualified as Objectives
import Shikigami.Objective.Types hiding (Cancelled, Completed)
import Shikigami.Prelude
import Shikigami.RecurringObjective.Generated.WorkflowRuntime qualified as Native
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Trigger.Schedule (CatchUpPolicy (SkipMissed))
import Shikigami.Trigger.Scheduler (SchedulerEnv (..))
import Shikigami.Trigger.Timer (runTimerPass)
import Shikigami.Workflow.Versioning (shikigamiWorkflowResumeOptions, shikigamiWorkflowRunOptions)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "MandateTimer"
    [ testCase "shared serving pass recovers a crashed claim; event and timer wake coalesce" $ withMandateFixture fixture \env request now ->
        Connection.withStore env.connectionSettings \store -> do
          _ <- admit env request
          let runtime = Objectives.ObjectiveRuntime env operatorHost.settings disabledDirectoryHandle allowAllActionAuthorizerForTests Nothing
              drive = run env (runWorkflowWith (shikigamiWorkflowRunOptions env) Native.workflowName (M.mandateWorkflowId request.mandateId) (Workflow.workflow (Just runtime) Nothing))
              scheduler = SchedulerEnv store.pool Map.empty [] Nothing Map.empty disabledDirectoryHandle SkipMissed Log.silentLogger
          drive >>= (@?= Suspended)
          before <- right =<< run env (Mandates.inspectMandate operatorHost request.mandateId)
          claimed <- run env (claimDueTimer (addUTCTime 100 now))
          row <- maybe (assertFailure "missing due mandate timer" >> fail "unreachable") pure claimed
          revise env request "current instructions replace old scheduled state"
          runTimerPass env Nothing scheduler (addUTCTime 400 now) >>= (@?= Right 1)
          drive >>= (@?= ContinuedAsNew)
          drive >>= (@?= Suspended)
          current <- right =<< run env (Mandates.inspectMandate operatorHost request.mandateId)
          goal <- right =<< run env (Owner.readObjective operatorHost request.objectiveId)
          current.watermark @?= Just (Mandates.checkpointMark goal)
          fmap (.number) current.lastCycle @?= Just 2
          run env (MandateTimer.fireAction row) >>= (@?= Nothing)
          after <- right =<< run env (Mandates.inspectMandate operatorHost request.mandateId)
          after @?= current
          assertBool "generation-owned wake replaced" (before.wake /= current.wake),
      testCase "cancellation disables the owned timer and late claimed rows cannot revive work" $ withMandateFixture fixture \env request now -> do
        _ <- admit env request
        let runtime = Objectives.ObjectiveRuntime env operatorHost.settings disabledDirectoryHandle allowAllActionAuthorizerForTests Nothing
            drive = run env (runWorkflowWith (shikigamiWorkflowRunOptions env) Native.workflowName (M.mandateWorkflowId request.mandateId) (Workflow.workflow (Just runtime) Nothing))
        drive >>= (@?= Suspended)
        original <- right =<< run env (Mandates.inspectMandate operatorHost request.mandateId)
        row <- run env (claimDueTimer (addUTCTime 10 now)) >>= maybe (assertFailure "timer missing" >> fail "unreachable") pure
        cancelled <- right =<< run env (Mandates.stopMandate operatorHost request.mandateId original.revision (fixtureOperationId "cancel"))
        run env (MandateTimer.fireAction row) >>= (@?= Nothing)
        cancelled.nextDue @?= Nothing
        timer <- run env (lookupTimer row.timerId)
        fmap (.status) timer @?= Just Timer.Cancelled
        drive >>= (@?= ContinuedAsNew)
        drive >>= (@?= Completed True)
        run env (Mandates.inspectMandate operatorHost request.mandateId) >>= (@?= Right cancelled)
    ]

withMandateFixture :: DatabaseFixture -> (AppEnv -> M.CreateRequest -> UTCTime -> IO a) -> IO a
withMandateFixture fixture action = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  let env = AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing
  void $ right =<< run env Catalog.registerProjectionCatalog
  now <- getCurrentTime
  let root = fixtureRootId "mandate-root"
      assignment = checked (parseObjectiveAssignmentId "supervised")
      worker = compatibilityIdentity (checked (mkAgentName "worker"))
      request = CreateRequest (checked (parseTitle "ongoing")) (checked (parseGoal "supervise current progress")) (checked (parseInstructions "first instructions")) [Criterion (checked (parseCriterionKey "review")) (checked (parseCriterionDescription "verify current evidence")) HumanVerifiable JourneyOptional] []
  void $ right =<< run env (Roots.enrollRoot root (R.Envelope (Map.fromList [(dimension, R.Limited (amount 10000)) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now)))
  created <- right =<< run env (Owner.createObjective operatorHost (fixtureOperationId "objective") Nothing request)
  let draft = AssignmentDraft assignment (checked (parseInstructions "current assignment")) [] worker Pending Nothing (Just root) (Just (addUTCTime 3600 now))
  void $ right =<< run env (Owner.executeCommand operatorHost created.objectiveId created.revision (fixtureOperationId "assignment") (SetAssignments [draft]))
  action env (M.CreateRequest (checked (M.parseMandateId "recurrence")) created.objectiveId root [assignment] [M.CurrentObjectiveCheckpoint] 1 (M.Cadence 1 8) (addUTCTime 600 now) M.ContinuingCoordinator M.WhenObjectiveTerminal) now

operatorHost :: Owner.ObjectiveHost
operatorHost = actorHost (LocalOperator (checked (parseOperatorId "recurrence-operator")))

actorHost :: AccessPrincipal -> Owner.ObjectiveHost
actorHost actor = Owner.ObjectiveHost (defaultObjectiveSettings & #enabled .~ ObjectivesEnabled & #operator .~ Just (checked (parseOperatorId "recurrence-operator")) & #administration .~ AdministerAll) (pure (Right actor)) allowAllActionAuthorizerForTests (\_ _ -> pure (Right ())) (\_ _ -> pure (Right ())) (\_ -> pure (Left ObjectiveInvalidEvidence))

runCycle :: AppEnv -> M.CreateRequest -> UTCTime -> IO M.Mandate
runCycle env request now = right =<< run env (Cycles.reconcileCycle operatorHost actorHost request.mandateId now)

admit :: AppEnv -> M.CreateRequest -> IO M.Mandate
admit env request = right =<< run env (Mandates.admitMandate operatorHost (fixtureOperationId "admit") request)

revise :: AppEnv -> M.CreateRequest -> Text -> IO ()
revise env request value = do
  current <- right =<< run env (Owner.readObjective operatorHost request.objectiveId)
  void $ right =<< run env (Owner.executeCommand operatorHost request.objectiveId current.revision (fixtureOperationId "revise-current-instructions") (ReviseInstructions (checked (parseInstructions value))))

count :: AppEnv -> Text -> IO Int
count env table = fromIntegral <$> run env (runTransaction (Tx.statement () (preparable ("SELECT count(*)::int4 FROM " <> table) E.noParams (D.singleRow (D.column (D.nonNullable D.int4))))))

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = right =<< runAppIO env action

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

checked :: (Show e) => Either e a -> a
checked = either (error . show) id

amount :: Integer -> ResourceAmount
amount = checked . parseResourceAmount

isRefusal :: (Show a) => Either ObjectiveError a -> IO ()
isRefusal = either (const (pure ())) (assertFailure . show)
