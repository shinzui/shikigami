module Shikigami.AgentWorkflowSpec (tests) where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.Aeson (object, (.=))
import Data.Bifunctor (first)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian, getCurrentTime, secondsToNominalDiffTime)
import Keiro.Outbox (listOutbox)
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowOutcome (..), completedStepName, loadStepIndex)
import Keiro.Workflow.Awakeable (AwakeableId)
import Keiro.Workflow.Awakeable.Schema (countPendingAwakeables)
import Keiro.Workflow.Resume (ResumeSummary (..), defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Keiro.Workflow.Sleep (runWorkflowTimerWorker)
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Id (SessionId)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Shikigami.Agent.Approval (ApprovalChannel (..), ApprovalDecision (..), ApprovalEnv (..), ApprovalRequest (..), ApprovalRequirement (..), approvalTimeoutFireAction, defaultApprovalEnv, resolveApproval)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.Workflow (AgentRunDeps (..), AgentRunHooks (..), agentRunRegistry, agentRunWorkflowName, defaultAgentRunHooks, runAgentRunWorkflow)
import Shikigami.Api.Agent (AgentDecl (..), Behavior (..), Sink (..), Trigger (..))
import Shikigami.Api.RunJob (RunJob (..), TriggerKind (..))
import Shikigami.Behavior.Run (BehaviorEnv, newBehaviorEnv)
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.Sink.Config (DanwaConfig (..), KawaConfig (..), KizashiConfig (..))
import Shikigami.Sink.Permission (SinkKind (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "AgentWorkflow"
    [ testCase "replays completed lifecycle steps for the same run id" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {store = kirokuStore, tracer, metrics = Nothing}
                deps = testDeps appEnv behaviorEnv defaultAgentRunHooks

            firstRun <- runAgentRunWorkflow deps job
            second <- runAgentRunWorkflow deps job
            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")

            case (firstRun, second) of
              (Right (Completed (Right firstResult)), Right (Completed (Right secondResult))) -> do
                assertEqual "open-session replayed the original session id" (sessionId firstResult) (sessionId secondResult)
                assertEqual "dispatch-sinks enqueued one stable outbox row" (Right 1) (length <$> outboxRows)
              other -> assertEqual "both workflow runs complete successfully" "completed twice" (show other),
      testCase "resumes after a crash without rerunning journaled step bodies" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            counts <- newIORef Map.empty
            shouldCrash <- newIORef True
            let appEnv = AppEnv {store = kirokuStore, tracer, metrics = Nothing}
                hooks =
                  defaultAgentRunHooks
                    { beforeStepBody = \stepName -> do
                        modifyIORef' counts (Map.insertWith (+) (unStepName stepName) (1 :: Int))
                        when (unStepName stepName == "run-behavior") do
                          crashNow <- atomicModifyIORef' shouldCrash \current -> (False, current)
                          when crashNow (ioError (userError "simulated crash in run-behavior"))
                    }
                deps = testDeps appEnv behaviorEnv hooks

            crashedRun <- try (runAgentRunWorkflow deps crashJob)
            case crashedRun of
              Left (_ :: SomeException) -> pure ()
              Right other -> assertEqual "first run should crash inside run-behavior" "exception" (show other)

            afterCrash <- readIORef counts
            assertEqual "journaled pre-behavior steps ran once before the crash" (Just 1) (Map.lookup "ingest-job" afterCrash)
            assertEqual "lookup-agent ran once before the crash" (Just 1) (Map.lookup "lookup-agent" afterCrash)
            assertEqual "open-session ran once before the crash" (Just 1) (Map.lookup "open-session" afterCrash)
            assertEqual "recall ran once before the crash" (Just 1) (Map.lookup "recall" afterCrash)
            assertEqual "run-behavior was attempted once before the crash" (Just 1) (Map.lookup "run-behavior" afterCrash)

            second <- runAgentRunWorkflow deps crashJob
            case second of
              Right (Completed (Right _result)) -> pure ()
              other -> assertEqual "second run should complete" "completed" (show other)

            finalCounts <- readIORef counts
            assertEqual "ingest-job replayed without rerunning" (Just 1) (Map.lookup "ingest-job" finalCounts)
            assertEqual "lookup-agent replayed without rerunning" (Just 1) (Map.lookup "lookup-agent" finalCounts)
            assertEqual "open-session replayed without rerunning" (Just 1) (Map.lookup "open-session" finalCounts)
            assertEqual "recall replayed without rerunning" (Just 1) (Map.lookup "recall" finalCounts)
            assertEqual "run-behavior reran after its failed attempt" (Just 2) (Map.lookup "run-behavior" finalCounts)
            assertEqual "record ran once after recovery" (Just 1) (Map.lookup "record" finalCounts)
            assertEqual "complete ran once after recovery" (Just 1) (Map.lookup "complete" finalCounts)

            stepKeys <- loadLifecycleStepKeys appEnv crashJob
            assertEqual "one row per completed lifecycle step" (Right expectedLifecycleSteps) stepKeys
            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            assertEqual "recovered run enqueued one stable outbox row" (Right 1) (length <$> outboxRows),
      testGroup
        "Approval"
        [ testCase "approved answer resumes and dispatches sink once" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                aidRef <- newIORef Nothing
                let appEnv = AppEnv {store = kirokuStore, tracer, metrics = Nothing}
                    deps = testDepsWithApproval appEnv behaviorEnv defaultAgentRunHooks (approvalEnv aidRef)

                parked <- runAgentRunWorkflow deps approvalJob
                case parked of
                  Right Suspended -> pure ()
                  other -> assertEqual "workflow parks for approval" "Suspended" (show other)

                pending <- runAppIO appEnv countPendingAwakeables
                assertEqual "one awakeable is pending while parked" (Right 1) pending
                beforeOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "sink is not dispatched before approval" (Right 0) (length <$> beforeOutbox)

                aid <- readCapturedAwakeable aidRef
                resolved <- resolveApproval appEnv aid (Approved (object ["approved" .= True]))
                assertBool "approval signal resolves the awakeable" resolved
                resumed <- runAppIO appEnv (resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps))
                assertEqual "resume pass completes the approved workflow" (Right 1) (completed <$> resumed)

                afterOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "approved sink is dispatched once" (Right 1) (length <$> afterOutbox),
          testCase "rejected answer resumes and suppresses sink dispatch" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                aidRef <- newIORef Nothing
                let appEnv = AppEnv {store = kirokuStore, tracer, metrics = Nothing}
                    deps = testDepsWithApproval appEnv behaviorEnv defaultAgentRunHooks (approvalEnv aidRef)

                parked <- runAgentRunWorkflow deps rejectedJob
                case parked of
                  Right Suspended -> pure ()
                  other -> assertEqual "workflow parks for approval" "Suspended" (show other)

                aid <- readCapturedAwakeable aidRef
                resolved <- resolveApproval appEnv aid (Rejected "not approved")
                assertBool "rejection signal resolves the awakeable" resolved
                resumed <- runAppIO appEnv (resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps))
                assertEqual "resume pass completes the rejected workflow" (Right 1) (completed <$> resumed)

                afterOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "rejected sink is suppressed" (Right 0) (length <$> afterOutbox)
        ],
      testGroup
        "Deadline"
        [ testCase "timeout resumes and suppresses sink dispatch" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                aidRef <- newIORef Nothing
                let appEnv = AppEnv {store = kirokuStore, tracer, metrics = Nothing}
                    deps = testDepsWithApprovalAndDeadline appEnv behaviorEnv defaultAgentRunHooks (approvalEnv aidRef) (Just (secondsToNominalDiffTime 1))

                parked <- runAgentRunWorkflow deps timeoutJob
                case parked of
                  Right Suspended -> pure ()
                  other -> assertEqual "workflow parks for approval deadline" "Suspended" (show other)

                fireDueApprovalTimer appEnv
                resumed <- runAppIO appEnv (resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps))
                assertEqual "resume pass completes the timed-out workflow" (Right 1) (completed <$> resumed)

                afterOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "timed-out sink is suppressed" (Right 0) (length <$> afterOutbox),
          testCase "approved answer before deadline wins over late timer" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                aidRef <- newIORef Nothing
                let appEnv = AppEnv {store = kirokuStore, tracer, metrics = Nothing}
                    deps = testDepsWithApprovalAndDeadline appEnv behaviorEnv defaultAgentRunHooks (approvalEnv aidRef) (Just (secondsToNominalDiffTime 1))

                parked <- runAgentRunWorkflow deps answeredBeforeDeadlineJob
                case parked of
                  Right Suspended -> pure ()
                  other -> assertEqual "workflow parks for approval deadline" "Suspended" (show other)

                aid <- readCapturedAwakeable aidRef
                resolved <- resolveApproval appEnv aid (Approved (object ["approved" .= True]))
                assertBool "approval signal resolves before deadline" resolved
                fireDueApprovalTimer appEnv
                resumed <- runAppIO appEnv (resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps))
                assertEqual "resume pass completes the approved workflow" (Right 1) (completed <$> resumed)

                afterOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "approved sink still dispatches once" (Right 1) (length <$> afterOutbox)
        ]
    ]

testDeps :: AppEnv -> BehaviorEnv -> AgentRunHooks -> AgentRunDeps
testDeps appEnv behaviorEnv hooks =
  testDepsWithApproval appEnv behaviorEnv hooks defaultApprovalEnv

testDepsWithApproval :: AppEnv -> BehaviorEnv -> AgentRunHooks -> (SessionId -> ApprovalEnv) -> AgentRunDeps
testDepsWithApproval appEnv behaviorEnv hooks approval =
  testDepsWithApprovalAndDeadline appEnv behaviorEnv hooks approval Nothing

testDepsWithApprovalAndDeadline :: AppEnv -> BehaviorEnv -> AgentRunHooks -> (SessionId -> ApprovalEnv) -> Maybe NominalDiffTime -> AgentRunDeps
testDepsWithApprovalAndDeadline appEnv behaviorEnv hooks approval deadline =
  AgentRunDeps
    { appEnv,
      behaviorEnv,
      agents = [decl],
      kizashi = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "recipient"},
      kawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = "shinzui/shikigami"},
      danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_test"},
      hooks,
      approval,
      deadline
    }

approvalEnv :: IORef (Maybe AwakeableId) -> SessionId -> ApprovalEnv
approvalEnv aidRef currentSession =
  ApprovalEnv
    { currentSession,
      requiresApproval = \_ kind _ ->
        pure
          if kind == SKawaDigest
            then ApprovalRequired approvalRequest
            else ApprovalNotRequired,
      recordPark = \_ aid _ -> writeIORef aidRef (Just aid),
      postAsk = \_ _ _ -> pure ()
    }

approvalRequest :: ApprovalRequest
approvalRequest =
  ApprovalRequest
    { prompt = "Dispatch heartbeat digest?",
      context = object ["source" .= ("test" :: Text)],
      channel = ViaDanwa
    }

readCapturedAwakeable :: IORef (Maybe AwakeableId) -> IO AwakeableId
readCapturedAwakeable aidRef =
  readIORef aidRef >>= \case
    Just aid -> pure aid
    Nothing -> ioError (userError "approval park should capture awakeable id")

fireDueApprovalTimer :: AppEnv -> IO ()
fireDueApprovalTimer appEnv = do
  now <- getCurrentTime
  fired <- runAppIO appEnv (runWorkflowTimerWorker Nothing (addUTCTime 2 now) approvalTimeoutFireAction)
  assertBool "approval timeout timer should fire" (either (const False) (maybe False (const True)) fired)

loadLifecycleStepKeys :: AppEnv -> RunJob -> IO (Either String (Set.Set Text))
loadLifecycleStepKeys appEnv runJob = do
  result <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (WorkflowId (idempotencyKey runJob)) 0)
  pure (first show (Set.delete completedStepName . Map.keysSet <$> result))

expectedLifecycleSteps :: Set.Set Text
expectedLifecycleSteps =
  Set.fromList
    [ "ingest-job",
      "lookup-agent",
      "open-session",
      "recall",
      "run-behavior",
      "dispatch-sinks",
      "record",
      "complete"
    ]

decl :: AgentDecl
decl =
  AgentDecl
    { name = "heartbeat",
      description = "workflow test agent",
      trigger = Event {eventType = "test"},
      behavior =
        ShikumiProgram
          { task = "noop-summary",
            preferEnrichment = False,
            grounding = Nothing,
            enabledBy = Nothing
          },
      sinks = [KawaDigest {subjectType = "heartbeat", verb = "heartbeat.tick"}]
    }

job :: RunJob
job =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-workflow-replay",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

crashJob :: RunJob
crashJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-workflow-crash-resume",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

approvalJob :: RunJob
approvalJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-approval-approved",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

rejectedJob :: RunJob
rejectedJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-approval-rejected",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

timeoutJob :: RunJob
timeoutJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-approval-timeout",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

answeredBeforeDeadlineJob :: RunJob
answeredBeforeDeadlineJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-approval-before-deadline",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }
