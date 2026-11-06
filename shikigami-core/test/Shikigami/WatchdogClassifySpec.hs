{-# LANGUAGE DataKinds #-}

module Shikigami.WatchdogClassifySpec (tests, fixtureSubjects, windows, instant, priorFor, verdictAt) where

import Control.Lens ((&), (.~))
import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime, addUTCTime)
import Keiro.Workflow.Types (WorkflowId (..))
import Shikigami.Agent.Approval (parseReviewRequestId)
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.Coordination.Observation qualified as Coordinator
import Shikigami.Duration (remainingDuration)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Counter (parseAttemptCount)
import Shikigami.Execution.Identity (newExecutionRootId, parseOperationId)
import Shikigami.Execution.Observation qualified as Execution
import Shikigami.Execution.Policy.Types (RecoveryClass (RepeatableObservation))
import Shikigami.Execution.Progress (noPendingReceipts)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.RootObservation qualified as Root
import Shikigami.Execution.Transcript qualified as Owner
import Shikigami.Objective.Observation qualified as Objective
import Shikigami.Objective.Types qualified as Objective
import Shikigami.StateRevision (advanceRevision, initialRevision)
import Shikigami.Watchdog.Classify
import Shikigami.Watchdog.Observation
import Shikigami.Watchdog.Types
import Shikigami.WorkerSession.Input (workerCoordinate, workerSessionId)
import Shikigami.WorkerSession.Observation qualified as Session
import Shikigami.WorkerSession.Types qualified as Session
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Watchdog Classify"
    [ testCase "accepted marks, not owner timestamps, govern every subject kind" do
        (coordinator, session, execution) <- fixtureSubjects
        mapM_
          ( \subject -> do
              observedVerdict (classify windows (addUTCTime 120 instant) Nothing subject) @?= Progressing
              verdictAt 20 subject @?= Progressing
              let changed = (priorFor subject) & #digest .~ markDigest (CoordinatorMark (CoordinatorActivity Objective.Blocked initialRevision Nothing Nothing 1 CoordinatorOpen))
              observedVerdict (classify windows (addUTCTime 120 instant) (Just changed) subject) @?= Progressing
              roundTrip (classify windows (addUTCTime 120 instant) (Just (priorFor subject)) subject)
          )
          [coordinator, session, execution]
        verdictAt 59 execution @?= Progressing
        verdictAt 60 execution @?= Stuck
        verdictAt 120 session @?= Stuck,
      testCase "all deadline waits are live only before their exact deadline" do
        (_, _, execution) <- fixtureSubjects
        review <- checked (parseReviewRequestId "review_00000000-0000-5000-8000-000000000000")
        operation <- checked (parseOperationId "fixture/operation")
        mapM_
          ( \(fact, reason, kind) -> do
              let future = execution & #waits .~ [fact (addUTCTime 121 instant)]
                  elapsed = execution & #waits .~ [fact (addUTCTime 120 instant)]
              verdictAt 120 future @?= Waiting (reason (addUTCTime 121 instant))
              verdictAt 120 elapsed @?= Stuck
              lapsedOf 120 elapsed @?= [kind]
          )
          [ (\time -> ApprovalWait time review, \time -> AwaitingApproval time review, ApprovalDeadline),
            (PermissionWait, AwaitingPermission, PermissionDeadline),
            (\time -> CommandWait time operation, \time -> RunningCommand time operation, CommandDeadline)
          ],
      testCase "parked grace ends at its window or an earlier root cutoff" do
        (_, session, _) <- fixtureSubjects
        let parked = session & #waits .~ [AssignmentParked]
        verdictAt 20 parked @?= Waiting (ParkedAssignment instant)
        verdictAt 120 parked @?= Stuck
        lapsedOf 120 parked @?= [ParkedDeadline]
        let cutoff = parked & #roots .~ [root & #cutoff .~ instant | root <- parked.roots]
        verdictAt 20 cutoff @?= Progressing
        verdictAt 120 cutoff @?= Stuck,
      testCase "blocked coordinator remains explicitly waiting" do
        (coordinator, _, _) <- fixtureSubjects
        verdictAt 120 (coordinator & #waits .~ [BlockedObjective]) @?= Waiting ObjectiveBlocked,
      testCase "persistent uncertainty is unresolved across subject kinds and attempt headers" do
        (_, session, execution) <- fixtureSubjects
        let unresolvedSession = session & #mark .~ case session.mark of SessionMark mark -> SessionMark (mark & #assignmentPhase .~ Just Session.AssignmentUnresolved); mark -> mark
            unresolvedExecution = execution & #mark .~ case execution.mark of ExecutionMark mark -> ExecutionMark (mark & #phase .~ Owner.Unresolved); mark -> mark
        mapM_
          ( \subject -> do
              verdictAt 59 subject @?= Progressing
              verdictAt 60 subject @?= Unresolved
          )
          [unresolvedSession, unresolvedExecution]
        let operationId = Owner.operationIdFor (Owner.executionIdentity "fixture-execution") initialRevision
            spec = Owner.OperationSpec operationId Owner.ModelTurn RepeatableObservation (Owner.executionCoordinate "model") (Owner.executionDigest "policy") (Owner.executionDigest "scope") Nothing
            operation attempts = Execution.OperationObservation operationId initialRevision spec Owner.NotMarkedUncertain Nothing attempts True
            withAttempt attempt = execution & #metadata .~ case execution.metadata of ExecutionMetadata metadata -> ExecutionMetadata (metadata & #operations .~ [operation [attempt]]); metadata -> metadata
        mapM_
          (\attempt -> verdictAt 120 (withAttempt attempt) @?= Unresolved)
          [Execution.AttemptObservation Attempt.AttemptUncertain (Just instant), Execution.AttemptObservation Attempt.DispatchStarted (Just (addUTCTime 120 instant)), Execution.AttemptObservation Attempt.AttemptSuperseded (Just instant)]
        verdictAt 120 (withAttempt (Execution.AttemptObservation Attempt.DispatchStarted (Just (addUTCTime 121 instant)))) @?= Stuck,
      testCase "terminal owner facts precede prior and incomplete relationships" do
        (coordinator, session, execution) <- fixtureSubjects
        let terminalCoordinator = coordinator & #mark .~ CoordinatorMark (CoordinatorActivity Objective.Open initialRevision Nothing Nothing 0 CoordinatorTerminal)
            terminalSession = session & #mark .~ case session.mark of SessionMark mark -> SessionMark (mark & #phase .~ Session.Cancelled); mark -> mark
            terminalExecution = execution & #mark .~ case execution.mark of ExecutionMark mark -> ExecutionMark (mark & #phase .~ Owner.Succeeded); mark -> mark
        mapM_ (\subject -> observedVerdict (classify windows instant Nothing (subject & #relationshipsComplete .~ Unknown)) @?= Terminal) [terminalCoordinator, terminalSession, terminalExecution],
      testCase "incomplete relationships hold episodes and never imply stuck or cleared work" do
        (coordinator, session, execution) <- fixtureSubjects
        mapM_ (\subject -> verdictAt 120 (subject & #relationshipsComplete .~ Unknown) @?= ObservationUnknown) [coordinator, session, execution],
      testCase "coordinator rule needs quiescent workers and has its own quiet window" do
        (coordinator, session, execution) <- fixtureSubjects
        let metadata = case session.metadata of SessionMetadata value _ -> Just value; _ -> Nothing
            withWorkers workers executions = coordinator & #metadata .~ case coordinator.metadata of ObjectiveMetadata objective control _ _ -> ObjectiveMetadata objective control workers executions; other -> other
        case metadata of
          Just worker -> do
            verdictAt 120 (withWorkers [worker] []) @?= Progressing
            verdictAt 120 session @?= Stuck
            verdictAt 89 (withWorkers [worker & #phase .~ Session.Idle] []) @?= Progressing
            verdictAt 90 (withWorkers [worker & #phase .~ Session.Idle] []) @?= StuckCoordinator
            verdictAt 120 (withWorkers [worker & #phase .~ Session.Idle & #queuedAssignments .~ 1] []) @?= Progressing
            verdictAt 20 (withWorkers [worker & #phase .~ Session.Parked] []) @?= Waiting (ParkedAssignment instant)
          Nothing -> assertFailure "session fixture missing"
        case execution.metadata of
          ExecutionMetadata value -> verdictAt 120 (withWorkers [] [value]) @?= Progressing
          _ -> assertFailure "execution fixture missing"
        verdictAt 90 coordinator @?= StuckCoordinator
        let withListener = coordinator & #metadata .~ case coordinator.metadata of ObjectiveMetadata objective (Just control) workers executions -> ObjectiveMetadata objective (Just (control & #listeners .~ [Coordinator.ListenerObservation "agent" "coordinator" 0 initialRevision])) workers executions; other -> other
        verdictAt 90 withListener @?= StuckCoordinator
        verdictAt 120 (coordinator & #waits .~ [PermissionWait (addUTCTime 121 instant)]) @?= Waiting (AwaitingPermission (addUTCTime 121 instant)),
      testCase "material summaries exclude elapsed time and evidence revisions" do
        (_, session, _) <- fixtureSubjects
        let summaryAt seconds source = evidenceSummary windows (addUTCTime seconds instant) instant StuckWork source
            digestAt seconds = summaryDigest . summaryAt seconds
        digestAt 120 session @?= digestAt 240 session
        digestAt 120 session @?= digestAt 120 (session & #evidence .~ (SessionEvidence (workerSessionId "other-reference") (advanceRevision initialRevision) :| []))
        let epoch = session & #mark .~ case session.mark of SessionMark mark -> SessionMark (mark & #epoch .~ advanceRevision initialRevision); mark -> mark
            stopped = session & #roots .~ [root & #cancelled .~ Resources.StopWork | root <- session.roots]
            elapsed = session & #waits .~ [PermissionWait instant]
        mapM_ (\source -> assertBool "material change" (digestAt 120 source /= digestAt 120 session)) [epoch, stopped, elapsed]
        roundTrip (summaryAt 120 session)
        roundTrip (digestAt 120 session),
      testCase "page classification pins coverage and observation limits" do
        (_, _, execution) <- fixtureSubjects
        let page = ObservationPage (addUTCTime 120 instant) initialCursor PassIncomplete [execution] []
            priors = Map.singleton (subjectKey execution.subject) (priorFor execution)
        case classifyPage windows page priors of
          [observed] -> case observed.outcome of
            Detected detection -> do
              detection.limit.scopeComplete @?= Unknown
              detection.limit.relationshipsComplete @?= Complete
              detection.window.firstSeenAt @?= instant
              detection.window.lastChangedAt @?= instant
              detection.window.observedAt @?= page.observedAt
              observed.prior @?= Just (priorFor execution)
            _ -> assertFailure (show observed)
          other -> assertFailure (show other)
    ]

instant :: UTCTime
instant = read "2026-11-04 00:00:00 UTC"

windows :: Windows
windows = Windows (remainingDuration 60) (remainingDuration 30) (remainingDuration 90) (remainingDuration 600)

priorFor :: SubjectObservation -> PriorMark
priorFor subject = PriorMark (markDigest subject.mark) instant instant

verdictAt :: Integer -> SubjectObservation -> Verdict
verdictAt seconds subject = observedVerdict (classify windows (addUTCTime (fromInteger seconds) instant) (Just (priorFor subject)) subject)

lapsedOf :: Integer -> SubjectObservation -> [DeadlineKind]
lapsedOf seconds subject = (evidenceSummary windows (addUTCTime (fromInteger seconds) instant) instant StuckWork subject).lapsed

fixtureSubjects :: IO (SubjectObservation, SubjectObservation, SubjectObservation)
fixtureSubjects = do
  rootId <- newExecutionRootId
  active <- checked (parseAttemptCount 0)
  unknown <- checked (parseAttemptCount 0)
  identity <- VerifiedIdentity <$> checked (mkAgentPrincipal "agent_worker")
  objectiveId <- checked (Objective.parseObjectiveId "shikigami_objective_01kwz3wy6wf8qv2pnwnb46qg1w")
  goal <- checked (Objective.parseGoal "Bounded fixture goal")
  let root = Root.RootObservation rootId initialRevision Resources.ContinueWork Resources.NoOverage (addUTCTime 3600 instant) active unknown
      sessionId = workerSessionId "fixture-session"
      executionId = Owner.executionIdentity "fixture-execution"
      sessionMetadata = Session.SessionObservation sessionId initialRevision initialRevision initialRevision initialRevision initialRevision Session.Active (Session.ObjectiveRef (workerCoordinate "fixture") (workerCoordinate "objective")) (Just objectiveId) rootId identity Nothing Nothing Nothing Nothing 0 True instant
      executionMetadata = Execution.ExecutionObservation executionId (WorkflowId "fixture-child") initialRevision initialRevision Owner.Active Nothing noPendingReceipts (Just rootId) (Just objectiveId) [] True True 0 Nothing instant
      objective = Objective.ObjectiveObservation objectiveId Objective.Open initialRevision initialRevision initialRevision goal [Objective.Member (Objective.RecordedAgent identity) [Objective.Coordinator]] [] [] 0 Nothing 0 True instant
      control = Coordinator.CoordinatorObservation objectiveId Nothing Nothing [] [] False True
      coordinator = SubjectObservation (ObjectiveCoordinator objectiveId) (Just objectiveId) (CoordinatorMark (CoordinatorActivity Objective.Open initialRevision Nothing Nothing 0 CoordinatorOpen)) [] (ObjectiveEvidence objectiveId initialRevision :| []) Complete (ObjectiveMetadata objective (Just control) [] []) [root] [] [] []
      session = SubjectObservation (WorkerSession sessionId) (Just objectiveId) (SessionMark (SessionActivity initialRevision initialRevision initialRevision initialRevision initialRevision Session.Active Nothing [])) [] (SessionEvidence sessionId initialRevision :| []) Complete (SessionMetadata sessionMetadata []) [root] [] [] []
      execution = SubjectObservation (Execution executionId) (Just objectiveId) (ExecutionMark (ExecutionActivity initialRevision initialRevision Owner.Active Nothing 0 noPendingReceipts)) [] (ExecutionEvidence executionId initialRevision :| []) Complete (ExecutionMetadata executionMetadata) [root] [] [] []
  pure (coordinator, session, execution)

checked :: (Show e) => Either e a -> IO a
checked = either (assertFailure . show) pure

roundTrip :: (Eq a, Show a, ToJSON a, FromJSON a) => a -> IO ()
roundTrip value = eitherDecode (encode value) @?= Right value
