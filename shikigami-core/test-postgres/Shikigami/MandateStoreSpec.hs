{-# LANGUAGE DataKinds #-}

module Shikigami.MandateStoreSpec (tests, withMandateFixture, run, right, operatorHost, actorHost) where

import Control.Concurrent.Async (replicateConcurrently)
import Data.Generics.Labels ()
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Timer (lookupTimer)
import Keiro.Workflow (StepName (..), WorkflowOutcome (..), runWorkflowWith)
import Keiro.Workflow.Resume (resumeWorkflowsOnce)
import Kiroku.Store.Connection (defaultConnectionSettings)
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
import Shikigami.Mandate.Cycle qualified as Cycles
import Shikigami.Mandate.Store qualified as Mandates
import Shikigami.Mandate.Types qualified as M
import Shikigami.Mandate.Wake qualified as Wake
import Shikigami.Mandate.Workflow qualified as Workflow
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Objective.Capability qualified as Owner
import Shikigami.Objective.Command
import Shikigami.Objective.Runtime qualified as Objectives
import Shikigami.Objective.Types hiding (Completed)
import Shikigami.Prelude
import Shikigami.RecurringCheckpointCycle.Generated.WorkflowRuntime qualified as Fresh
import Shikigami.RecurringObjective.Generated.WorkflowRuntime qualified as Native
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Workflow.Versioning (admitWorkflowInput, shikigamiWorkflowResumeOptions, shikigamiWorkflowRunOptions)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "MandateStore"
    [ testCase "verified finite objective completion creates no recurring authority" $ withMandateFixture fixture \env request _ -> do
        complete env request
        count env "shikigami.mandates" >>= (@?= 0),
      testCase "explicit admission retries recover one mandate and native input" $ withMandateFixture fixture \env request _ -> do
        first <- admit env request
        replay <- admit env request
        first @?= replay
        first.nextDue @?= replay.nextDue
        count env "shikigami.mandates" >>= (@?= 1)
        run env (Mandates.admitMandate operatorHost (fixtureOperationId "admit") (request & #cadence . #seconds .~ 2)) >>= (@?= Left ObjectiveConflict),
      testCase "missing, foreign and unbounded roots refuse without an orphan mandate" $ withMandateFixture fixture \env request _ -> do
        run env (Mandates.admitMandate operatorHost (fixtureOperationId "missing") (request & #rootId .~ fixtureRootId "missing")) >>= isRefusal
        foreignRoot <- pure (fixtureRootId "foreign")
        void $ right =<< run env (Roots.enrollRoot foreignRoot (R.Envelope Map.empty request.expiresAt))
        run env (Mandates.admitMandate operatorHost (fixtureOperationId "foreign") (request & #rootId .~ foreignRoot)) >>= isRefusal
        count env "shikigami.mandates" >>= (@?= 0),
      testCase "schedule edits require fresh current coordination authority and exact version" $ withMandateFixture fixture \env request now -> do
        first <- admit env request
        let update = M.ScheduleUpdate (M.Cadence 2 8) (addUTCTime 100 now)
            denied = actorHost (VerifiedCaller (checked (parseCallerId "reader")))
        run env (Mandates.updateMandate denied request.mandateId first.revision (fixtureOperationId "denied") update) >>= isRefusal
        run env (Mandates.updateMandate (operatorHost & #settings . #enabled .~ ObjectivesDisabled) request.mandateId first.revision (fixtureOperationId "disabled") update) >>= (@?= Left ObjectiveDenied)
        edited <- right =<< run env (Mandates.updateMandate operatorHost request.mandateId first.revision (fixtureOperationId "update") update)
        run env (Mandates.updateMandate operatorHost request.mandateId first.revision (fixtureOperationId "update") update) >>= (@?= Right edited)
        run env (Mandates.updateMandate operatorHost request.mandateId first.revision (fixtureOperationId "stale") update) >>= (@?= Left ObjectiveConflict)
        run env (Mandates.updateMandate operatorHost request.mandateId edited.revision (fixtureOperationId "too-long") (update & #expiresAt .~ addUTCTime 5000 now)) >>= isRefusal,
      testCase "successful ongoing runCycle retains mandate, exact checkpoint receipt and root" $ withMandateFixture fixture \env request now -> do
        _ <- admit env request
        before <- right =<< run env (Roots.inspectRoot request.rootId)
        finished <- runCycle env request now
        assertBool "ongoing mandate stays active" (isNothing finished.stopReason && isJust finished.nextDue)
        current <- right =<< run env (Owner.readObjective operatorHost request.objectiveId)
        finished.watermark @?= Just (Mandates.checkpointMark current)
        let last = fromMaybe (error "missing runCycle") finished.lastCycle
        last.rootId @?= request.rootId
        assertBool "accepted owner progress" (not (null last.progress))
        run env (Roots.inspectRoot request.rootId) >>= (@?= Right before),
      testCase "concurrent event and timer wakes coalesce into one accepted active runCycle" $ withMandateFixture fixture \env request now -> do
        _ <- admit env request
        attempts <- replicateConcurrently 8 (run env (Cycles.acceptWake operatorHost request.mandateId now))
        let accepted = [state | Right state <- attempts]
        assertBool "one or more replies survived contention" (not (null accepted))
        length (nub (map (.activeCycle) accepted)) @?= 1
        completed <- right =<< run env (Cycles.commitCycleProgress operatorHost request.mandateId now)
        count env "shikigami.mandate_cycles" >>= (@?= 1)
        run env (Cycles.commitCycleProgress operatorHost request.mandateId now) >>= (@?= Right completed),
      testCase "replacement instructions before commit supersede an old checkpoint" $ withMandateFixture fixture \env request now -> do
        _ <- admit env request
        _ <- right =<< run env (Cycles.acceptWake operatorHost request.mandateId now)
        revise env request "new authorized instructions"
        previous <- right =<< run env (Owner.readObjective operatorHost request.objectiveId)
        let replacement = (head previous.assignments).definition & #owner .~ compatibilityIdentity (checked (mkAgentName "replacement-worker")) & #instructions .~ checked (parseInstructions "replacement assignment")
        void $ right =<< run env (Owner.executeCommand operatorHost request.objectiveId previous.revision (fixtureOperationId "replace-assignment") (SetAssignments [replacement]))
        done <- right =<< run env (Cycles.commitCycleProgress operatorHost request.mandateId now)
        goal <- right =<< run env (Owner.readObjective operatorHost request.objectiveId)
        done.watermark @?= Just (Mandates.checkpointMark goal)
        fmap (.instructionsRevision) done.lastCycle @?= Just goal.instructionsRevision,
      testCase "idle backoff produces no repeated progress, workers, attempts or notifications; new evidence resumes once" $ withMandateFixture fixture \env request now -> do
        _ <- admit env request
        first <- runCycle env request now
        receipts <- count env "shikigami.objective_receipts"
        root <- right =<< run env (Roots.inspectRoot request.rootId)
        forM_ [1 .. 5 :: Int] \offset -> do
          idle <- runCycle env request (addUTCTime (fromIntegral offset) now)
          idle.lastCycle @?= first.lastCycle
          assertBool "backoff capped at admitted interval" (idle.nextDue <= Just (addUTCTime (fromIntegral (offset + 8)) now))
        count env "shikigami.mandate_cycles" >>= (@?= 1)
        count env "shikigami.objective_receipts" >>= (@?= receipts)
        count env "shikigami.worker_sessions" >>= (@?= 0)
        count env "shikigami.execution_attempts" >>= (@?= 0)
        run env (Roots.inspectRoot request.rootId) >>= (@?= Right root)
        revise env request "new evidence"
        changed <- runCycle env request (addUTCTime 6 now)
        fmap (.number) changed.lastCycle @?= Just 2
        _ <- runCycle env request (addUTCTime 7 now)
        count env "shikigami.mandate_cycles" >>= (@?= 2),
      testCase "expiry stops admission and late wakes cannot revive the mandate" $ withMandateFixture fixture \env request now -> do
        _ <- admit env request
        held <- unknownRoot env request now
        stopped <- runCycle env request (addUTCTime 601 now)
        stopped.stopReason @?= Just M.Expired
        stopped.nextDue @?= Nothing
        run env (Roots.inspectRoot request.rootId) >>= (@?= Right held)
        run env (Cycles.acceptWake operatorHost request.mandateId (addUTCTime 602 now)) >>= (@?= Right stopped),
      testCase "revoked coordinator is stopped by process maintenance without authority elevation" $ withMandateFixture fixture \env request now -> do
        let actor = VerifiedCaller (checked (parseCallerId "coordinator"))
            host = actorHost actor
        goal <- right =<< run env (Owner.readObjective operatorHost request.objectiveId)
        void $ right =<< run env (Owner.executeCommand operatorHost request.objectiveId goal.revision (fixtureOperationId "grant") (GrantMember actor [Coordinator]))
        _ <- right =<< run env (Mandates.admitMandate host (fixtureOperationId "admit") request)
        held <- unknownRoot env request now
        current <- right =<< run env (Owner.readObjective operatorHost request.objectiveId)
        void $ right =<< run env (Owner.executeCommand operatorHost request.objectiveId current.revision (fixtureOperationId "revoke") (RevokeMember actor))
        stopped <- right =<< run env (Cycles.reconcileCycle operatorHost actorHost request.mandateId now)
        stopped.stopReason @?= Just M.Revoked
        run env (Roots.inspectRoot request.rootId) >>= (@?= Right held)
        stopped.lastCycle @?= Nothing,
      testCase "reducing an active coordinator to reader stops admission and preserves the accepted cycle" $ withMandateFixture fixture \env request now -> do
        let actor = VerifiedCaller (checked (parseCallerId "coordinator"))
            host = actorHost actor
            membership key roles = do
              goal <- right =<< run env (Owner.readObjective operatorHost request.objectiveId)
              void $ right =<< run env (Owner.executeCommand operatorHost request.objectiveId goal.revision (fixtureOperationId key) (GrantMember actor roles))
        membership "grant" [Coordinator]
        _ <- right =<< run env (Mandates.admitMandate host (fixtureOperationId "admit") request)
        active <- right =<< run env (Cycles.acceptWake host request.mandateId now)
        membership "reader-only" [Reader]
        stopped <- right =<< run env (Cycles.reconcileCycle operatorHost actorHost request.mandateId now)
        stopped.stopReason @?= Just M.Revoked
        stopped.activeCycle @?= active.activeCycle
        count env "shikigami.mandate_cycles" >>= (@?= 0),
      testCase "cancellation preserves an accepted uncertain attempt and root reservations" $ withMandateFixture fixture \env request now -> do
        first <- admit env request
        held <- unknownRoot env request now
        stopped <- right =<< run env (Mandates.stopMandate operatorHost request.mandateId first.revision (fixtureOperationId "cancel"))
        stopped.stopReason @?= Just M.CancelledByCaller
        (_, inspectedRoot) <- right =<< run env (Mandates.inspectWithResources operatorHost request.mandateId)
        inspectedRoot @?= held
        _ <- runCycle env request now
        run env (Roots.inspectRoot request.rootId) >>= (@?= Right held)
        run env (Mandates.updateMandate operatorHost request.mandateId stopped.revision (fixtureOperationId "revive") (M.ScheduleUpdate request.cadence request.expiresAt)) >>= isRefusal,
      testCase "verified objective completion closes recurring admission" $ withMandateFixture fixture \env request now -> do
        _ <- admit env request
        _ <- runCycle env request now
        complete env request
        stopped <- runCycle env request now
        stopped.stopReason @?= Just M.ObjectiveFinished,
      testCase "restart after progress before timer publication repairs the wake without replaying evidence" $ withMandateFixture fixture \env request now -> do
        _ <- admit env request
        done <- runCycle env request now
        let runtime = Objectives.ObjectiveRuntime env operatorHost.settings disabledDirectoryHandle allowAllActionAuthorizerForTests Nothing
            drive = run env (runWorkflowWith (shikigamiWorkflowRunOptions env) Native.workflowName (M.mandateWorkflowId request.mandateId) (Workflow.workflow (Just runtime) Nothing))
        -- Discard all caller state after a committed runCycle, as a lost process
        -- would. Native input was coupled to admission; no caller seed is needed.
        outcome <- drive
        outcome @?= Suspended
        retained <- right =<< run env (Mandates.inspectMandate operatorHost request.mandateId)
        retained.watermark @?= done.watermark
        count env "shikigami.mandate_cycles" >>= (@?= 1)
        listener <- maybe (assertFailure "missing published wake" >> fail "unreachable") pure retained.wake
        timer <- run env (lookupTimer (Wake.timerIdFor request.mandateId listener))
        assertBool "desired wake installed after restart" (isJust timer),
      testCase "fresh child discovered before input publication suspends and recovers the same checkpoint" $ withMandateFixture fixture \env request _ -> do
        _ <- admit env request
        let runtime = Objectives.ObjectiveRuntime env operatorHost.settings disabledDirectoryHandle allowAllActionAuthorizerForTests Nothing
            input = Workflow.CycleStart request.mandateId initialRevision
            child = Workflow.cycleWorkflowId input
            drive = run env (runWorkflowWith (shikigamiWorkflowRunOptions env) Fresh.workflowName child (Workflow.freshWorkflow (Just runtime)))
        drive >>= (@?= Suspended)
        count env "shikigami.mandate_cycles" >>= (@?= 0)
        run env (admitWorkflowInput Fresh.workflowName child (StepName "ingest-mandate-cycle") (toJSON input))
        first <- drive
        case first of
          Completed state -> fmap (.rootId) state.lastCycle @?= Just request.rootId
          other -> assertFailure (show other)
        drive >>= (@?= first)
        count env "shikigami.mandate_cycles" >>= (@?= 1),
      testCase "fresh bounded native cycles resume through the registered child and retain their root" $ withMandateFixture fixture \env request now -> do
        let fresh = request & #mode .~ M.FreshCycleRun
            runtime = Objectives.ObjectiveRuntime env operatorHost.settings disabledDirectoryHandle allowAllActionAuthorizerForTests Nothing
        _ <- admit env fresh
        forM_ [1 .. 8 :: Int] \_ -> void $ run env (resumeWorkflowsOnce (shikigamiWorkflowResumeOptions env 30) (Workflow.registry (Just runtime)))
        state <- right =<< run env (Mandates.inspectMandate operatorHost request.mandateId)
        assertBool "fresh runCycle completed and supervisor remains active" (isJust state.lastCycle && isNothing state.stopReason && isJust state.wake)
        fmap (.rootId) state.lastCycle @?= Just request.rootId
        count env "shikigami.mandate_cycles" >>= (@?= 1)
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

unknownRoot :: AppEnv -> M.CreateRequest -> UTCTime -> IO R.Root
unknownRoot env request now = do
  let operation = R.OperationRequest (fixtureOperationId "pending") Nothing R.ModelOperation Map.empty (executionCoordinate "read-only")
      attempt = R.AttemptRequest (fixtureAttemptId "unknown") operation.operationId (Map.fromList [(R.ActiveWork, amount 1), (R.ModelAttempts, amount 1), (R.Tokens, amount 10), (R.CostMicroUsd, amount 0)]) R.EnforcedCeiling
  void $ right =<< run env (Roots.reserveOperation request.rootId initialRevision operation now)
  void $ right =<< run env (Roots.beginAttempt request.rootId initialRevision attempt now)
  void $ right =<< run env (Roots.settleAttempt request.rootId attempt.attemptId (R.UnknownUsage "lost external acknowledgement"))
  right =<< run env (Roots.inspectRoot request.rootId)

admit :: AppEnv -> M.CreateRequest -> IO M.Mandate
admit env request = right =<< run env (Mandates.admitMandate operatorHost (fixtureOperationId "admit") request)

revise :: AppEnv -> M.CreateRequest -> Text -> IO ()
revise env request value = do
  current <- right =<< run env (Owner.readObjective operatorHost request.objectiveId)
  void $ right =<< run env (Owner.executeCommand operatorHost request.objectiveId current.revision (fixtureOperationId "revise-current-instructions") (ReviseInstructions (checked (parseInstructions value))))

complete :: AppEnv -> M.CreateRequest -> IO ()
complete env request = do
  let artifact = checked (parseArtifactRef "fixture-reviewed-artifact")
      evidence = checked (parseEvidenceKey "review")
      assignment = head request.scope
      send key command = do
        current <- right =<< run env (Owner.readObjective operatorHost request.objectiveId)
        void $ right =<< run env (Owner.executeCommand operatorHost request.objectiveId current.revision (fixtureOperationId key) command)
  send "done" (RecordProgress assignment Done [] [])
  send "attest" (RecordEvidence assignment (Attestation evidence (checked (parseCriterionKey "review")) artifact (checked (parseAttestationStatement "Reviewed current integrated fixture")) NoJourney))
  current <- right =<< run env (Owner.readObjective operatorHost request.objectiveId)
  send "proposal" (ProposeCompletion (CompletionProposal current.revision current.instructionsRevision current.criteriaRevision [artifact] [evidence] []))
  send "accept" AcceptCompletion
  completed <- right =<< run env (Owner.readObjective operatorHost request.objectiveId)
  assertBool "objective owner accepted completion" (isJust completed.acceptance)

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
