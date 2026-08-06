module Shikigami.AgentWorkflowSpec (tests) where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.Aeson (Value, object, (.=))
import Data.Bifunctor (first)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian, getCurrentTime, secondsToNominalDiffTime)
import Effectful (Eff)
import Keiro.Integration.Event (decodeJsonIntegrationEvent)
import Keiro.Outbox (OutboxRow (..), listOutbox)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), completedStepName, defaultWorkflowRunOptions, loadStepIndex, runWorkflow)
import Keiro.Workflow.Awakeable (AwakeableId)
import Keiro.Workflow.Awakeable.Schema (countPendingAwakeables)
import Keiro.Workflow.Child (runChildWorkflow)
import Keiro.Workflow.Child.Schema (ChildRow (..), ChildStatus (..), lookupChildrenOfParent)
import Keiro.Workflow.Resume (ResumeSummary (..), defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Keiro.Workflow.Sleep (runWorkflowTimerWorker)
import Kioku.Api.Types (Confidence (MediumConfidence), MemoryType (MemoryPattern))
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kioku.Id (SessionId, genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Session (SessionRow (..))
import Kioku.Session qualified as Session
import Kioku.Session.ReadModel (TurnRow (..))
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Shikigami.Agent.Approval (ApprovalChannel (..), ApprovalDecision (..), ApprovalEnv (..), ApprovalRequest (..), ApprovalRequirement (..), approvalTimeoutFireAction, defaultApprovalEnv, resolveApproval)
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Sink (..), Trigger (..))
import Shikigami.Agent.Delegate (awaitDelegated, delegate, delegatedWorkflowId)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.RunJob (RunJob (..), TriggerKind (..))
import Shikigami.Agent.Workflow (AgentRunDeps (..), AgentRunHooks (..), SinkIntent (..), agentRunRegistry, agentRunWorkflow, agentRunWorkflowName, defaultAgentRunHooks, runAgentRunWorkflow)
import Shikigami.Behavior.Run (BehaviorEnv, newBehaviorEnv)
import Shikigami.Integration.Danwa (AddressedMessage (..), addressedMessageEventType)
import Shikigami.Log qualified as Log
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.Sink (GrantSource (StaticGrants), defaultGrantTable)
import Shikigami.Sink.Config (DanwaConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Sink.Permission (SinkKind (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "AgentWorkflow"
    [ testCase "replays completed lifecycle steps for the same run id" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                deps = testDeps appEnv behaviorEnv defaultAgentRunHooks

            firstRun <- runAgentRunWorkflow deps job
            second <- runAgentRunWorkflow deps job
            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")

            case (firstRun, second) of
              (Right (Completed (Right AgentRunResult {sessionId = firstSessionId})), Right (Completed (Right AgentRunResult {sessionId = secondSessionId}))) -> do
                assertEqual "open-session replayed the original session id" firstSessionId secondSessionId
                assertEqual "dispatch-sinks enqueued one stable outbox row" (Right 1) (length <$> outboxRows)
              other -> assertEqual "both workflow runs complete successfully" "completed twice" (show other),
      testCase "resumes after a crash without rerunning journaled step bodies" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            counts <- newIORef Map.empty
            shouldCrash <- newIORef True
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
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
      testCase "resumes after a crash between record and complete without duplicating memory" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            counts <- newIORef Map.empty
            shouldCrash <- newIORef True
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                hooks =
                  defaultAgentRunHooks
                    { beforeStepBody = \stepName -> do
                        modifyIORef' counts (Map.insertWith (+) (unStepName stepName) (1 :: Int))
                        when (unStepName stepName == "complete") do
                          crashNow <- atomicModifyIORef' shouldCrash \current -> (False, current)
                          when crashNow (ioError (userError "simulated crash before complete"))
                    }
                deps = testDeps appEnv behaviorEnv hooks

            crashedRun <- try (runAgentRunWorkflow deps recordBeforeCompleteCrashJob)
            case crashedRun of
              Left (_ :: SomeException) -> pure ()
              Right other -> assertEqual "first run should crash before complete" "exception" (show other)

            afterCrash <- readIORef counts
            assertEqual "record step completed before the crash" (Just 1) (Map.lookup "record" afterCrash)
            assertEqual "complete step was reached once before the crash" (Just 1) (Map.lookup "complete" afterCrash)

            resumed <- runAgentRunWorkflow deps recordBeforeCompleteCrashJob
            sid <- case resumed of
              Right (Completed (Right AgentRunResult {sessionId})) -> pure sessionId
              other -> assertFailure ("resumed run should complete, got " <> show other)

            finalCounts <- readIORef counts
            assertEqual "record replayed without rerunning" (Just 1) (Map.lookup "record" finalCounts)
            assertEqual "complete body ran once after recovery" (Just 2) (Map.lookup "complete" finalCounts)

            memories <- runAppIO appEnv (Memory.getRowsBySession sid)
            case memories of
              Right (Right rows) -> assertEqual "exactly one memory row for the resumed session" 1 (length rows)
              other -> assertFailure ("memory lookup should succeed, got " <> show other)

            session <- runAppIO appEnv (Session.getById sid)
            case session of
              Right (Right (Just SessionRow {status, modelUsed})) -> do
                assertEqual "session completed after resume" "completed" status
                -- The durable half of the promise that a stub never passes for
                -- a model: whatever answered is named on the row, so a run made
                -- without a model is identifiable long after the process that
                -- logged its provider has gone.
                assertEqual "the completed session names the model that answered" (Just "stub-v1") modelUsed
              other -> assertFailure ("session lookup should return completed row, got " <> show other),
      testCase "runs Flow behavior through the agent workflow" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [flowDecl]

            result <- runAgentRunWorkflow deps flowJob
            case result of
              Right (Completed (Right AgentRunResult {behaviorOutput})) ->
                assertEqual "flow behavior returns its classified verdict" expectedFlowOutput behaviorOutput
              other -> assertFailure ("flow behavior should complete, got " <> show other)

            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            assertEqual "low-risk flow emits no sink outbox rows" (Right 0) (length <$> outboxRows),
      -- The durable half of the memory proof. The pure rules live in
      -- "Shikigami.BehaviorInputSpec"; this runs the whole
      -- open-session → recall → flow → emit pipeline against a real database
      -- and shows a decision changed by something the agent learned earlier.
      --
      -- The payload is the same calm text the low-risk case above uses, and the
      -- flow reaches the opposite verdict — so it is memory, not the trigger,
      -- that moved it. Recall works without a vector extension because
      -- 'Shikigami.Agent.Run.recallPriorLearnings' falls back to
      -- @getActiveByScope@, which makes this deterministic in CI.
      testCase "a recalled escalation flips the flow's verdict on a calm payload" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [flowDecl]

            recordPriorEscalation appEnv (idempotencyKey flowMemoryJob)

            -- A high verdict emits its alert and then parks awaiting
            -- acknowledgement; the low case above completes outright. Parking
            -- is itself the branch evidence, and the emitted row carries the
            -- verdict that caused it.
            parked <- runAgentRunWorkflow deps flowMemoryJob
            case parked of
              Right Suspended -> pure ()
              other -> assertEqual "high-risk flow parks awaiting acknowledgement" "Suspended" (show other)

            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            case outboxRows of
              Right [OutboxRow {event}] ->
                case decodeJsonIntegrationEvent event of
                  Right SinkIntent {output} ->
                    assertEqual
                      "the emitted signal carries a verdict the recalled memory forced"
                      ( object
                          [ "level" .= ("high" :: Text),
                            "rationale" .= ("prior escalation on this subject: customer relationship at risk" :: Text),
                            "ticketId" .= idempotencyKey flowMemoryJob
                          ]
                      )
                      output
                  Left err -> assertFailure ("the outbox row should decode as a sink intent, got " <> show err)
              other -> assertFailure ("expected exactly one emitted signal, got " <> show (fmap length other)),
      testGroup
        "Conversation"
        [ testCase "parks and resumes a danwa conversation as one workflow session" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    env =
                      Conversation.ConversationEnv
                        { Conversation.appEnv = appEnv,
                          Conversation.behaviorEnv = behaviorEnv,
                          Conversation.danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_test"},
                          Conversation.agents = [conversationDecl],
                          Conversation.grants = StaticGrants defaultGrantTable
                        }

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                secondTurn <- Conversation.runConversationTurn env conversationDecl secondAddressedMessage

                case (firstTurn, secondTurn) of
                  (Right firstResult, Right secondResult) -> do
                    assertEqual "second human turn reuses the first kioku session" (Conversation.sessionId firstResult) (Conversation.sessionId secondResult)
                    assertBool "first reply is represented by a durable outbox message" ("outbox:danwa-conversation:conv_thread_1:danwa-reply:msg_human_1" `Text.isPrefixOf` Conversation.replyMessageId firstResult)
                    assertBool "second reply is represented by a durable outbox message" ("outbox:danwa-conversation:conv_thread_1:danwa-reply:msg_human_2" `Text.isPrefixOf` Conversation.replyMessageId secondResult)

                    turns <- runAppIO appEnv (Session.getTurns (Conversation.sessionId firstResult))
                    case turns of
                      Right (Right rows) ->
                        assertEqual
                          "one conversation session records user/assistant/user/assistant"
                          [("user", 0), ("assistant", 1), ("user", 2), ("assistant", 3)]
                          (turnRoleIndex <$> rows)
                      other -> assertFailure ("getTurns should return conversation turns, got " <> show (first (const ("store-error" :: String)) other))

                    outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                    assertEqual "two danwa replies are queued through the outbox" (Right 2) (length <$> outboxRows)

                    pending <- runAppIO appEnv countPendingAwakeables
                    assertEqual "workflow parks again after the second reply" (Right 1) pending

                    stepKeys <- runAppIO appEnv (loadStepIndex Conversation.conversationWorkflowName (Conversation.conversationWorkflowId firstAddressedMessage) 0)
                    case stepKeys of
                      Right keys -> do
                        assertBool "first turn result is journaled" (Map.member "turn-result:msg_human_1" keys)
                        assertBool "second turn result is journaled after resume" (Map.member "turn-result:msg_human_2" keys)
                        assertBool "first assistant turn and reply are one durable step" (Map.member "record-assistant-and-reply:msg_human_1" keys)
                        assertBool "second assistant turn and reply are one durable step" (Map.member "record-assistant-and-reply:msg_human_2" keys)
                        assertBool "first reply is not journaled as a separate sink step" (not (Map.member "danwa-reply:msg_human_1" keys))
                        assertBool "second reply is not journaled as a separate sink step" (not (Map.member "danwa-reply:msg_human_2" keys))
                        assertBool "first park allocated an input awakeable" (any (Text.isPrefixOf "awkid:next-message:1") (Map.keys keys))
                      Left err -> assertFailure ("loadStepIndex failed: " <> show err)
                  other -> assertFailure ("conversation turns should succeed, got " <> show other)
        ],
      testGroup
        "Delegate"
        [ testCase "parent suspends awaiting delegated child and resumes with child output" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                parentSession <- genSessionId
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    deps = testDeps appEnv behaviorEnv defaultAgentRunHooks
                    parentWorkflowName = WorkflowName "shikigami.test-delegate-parent"
                    parentWorkflowId = WorkflowId "delegate-parent-1"
                    childWorkflowId = delegatedWorkflowId parentWorkflowId "heartbeat" 0
                    parentBody = parentDelegateWorkflow parentSession

                parked <- runAppIO appEnv (runWorkflow parentWorkflowName parentWorkflowId parentBody)
                assertEqual "parent parks on delegated child" (Right Suspended) parked

                childRun <-
                  runAppIO appEnv $
                    runChildWorkflow
                      defaultWorkflowRunOptions
                      agentRunWorkflowName
                      childWorkflowId
                      (agentRunWorkflow deps Nothing)
                childOutput <-
                  case childRun of
                    Right (Completed (Right AgentRunResult {behaviorOutput = childBehaviorOutput})) -> pure childBehaviorOutput
                    other -> assertFailure ("child agent workflow should complete, got " <> show other)

                resumed <- runAppIO appEnv (runWorkflow parentWorkflowName parentWorkflowId parentBody)
                assertEqual "parent resumes with child behavior output" (Right (Completed childOutput)) resumed,
          testCase "proof supervisor fans out to specialists and records lineage" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                proofAgents <- loadProofAgents
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                    deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks proofAgents
                    parentWorkflowId = WorkflowId "research-supervisor:test-fanout"
                    webWorkflowId = delegatedWorkflowId parentWorkflowId "web-researcher" 0
                    codeWorkflowId = delegatedWorkflowId parentWorkflowId "code-researcher" 1
                    WorkflowId webWorkflowIdText = webWorkflowId
                    WorkflowId codeWorkflowIdText = codeWorkflowId
                    expectedRunningChildLinks =
                      Set.fromList
                        [ ("shikigami.agent-run", webWorkflowIdText, "running"),
                          ("shikigami.agent-run", codeWorkflowIdText, "running")
                        ]

                parked <- runAgentRunWorkflow deps researchSupervisorJob
                assertEqual "research supervisor parks after spawning children" (Right Suspended) parked
                childLinksAfterPark <- runAppIO appEnv (lookupChildrenOfParent "research-supervisor:test-fanout" "shikigami.agent-run")
                assertEqual
                  "initial park creates two running child workflow links"
                  (Right expectedRunningChildLinks)
                  (childLinkSummary <$> childLinksAfterPark)

                replayedWhileChildrenPending <- runAgentRunWorkflow deps researchSupervisorJob
                assertEqual "parent replay while children are pending parks again" (Right Suspended) replayedWhileChildrenPending
                childLinksAfterReplay <- runAppIO appEnv (lookupChildrenOfParent "research-supervisor:test-fanout" "shikigami.agent-run")
                assertEqual
                  "parent replay does not duplicate delegated children"
                  (childLinkSummary <$> childLinksAfterPark)
                  (childLinkSummary <$> childLinksAfterReplay)

                webRun <-
                  runAppIO appEnv $
                    runChildWorkflow
                      defaultWorkflowRunOptions
                      agentRunWorkflowName
                      webWorkflowId
                      (agentRunWorkflow deps Nothing)
                assertChildCompleted "web specialist completes" webRun

                codeRun <-
                  runAppIO appEnv $
                    runChildWorkflow
                      defaultWorkflowRunOptions
                      agentRunWorkflowName
                      codeWorkflowId
                      (agentRunWorkflow deps Nothing)
                assertChildCompleted "code specialist completes" codeRun

                resumed <- runAgentRunWorkflow deps researchSupervisorJob
                parentSession <-
                  case resumed of
                    Right (Completed (Right AgentRunResult {sessionId = parentSessionId', behaviorOutput})) -> do
                      assertEqual "supervisor synthesizes both findings" expectedSupervisorOutput behaviorOutput
                      pure parentSessionId'
                    other -> assertFailure ("research supervisor should complete after children, got " <> show other)

                children <- runAppIO appEnv (Session.getDelegationChildren parentSession)
                case children of
                  Right (Right rows) ->
                    assertEqual
                      "kioku records both delegated child sessions"
                      ( Set.fromList
                          [ ("web-researcher", Just (idText parentSession), 1),
                            ("code-researcher", Just (idText parentSession), 1)
                          ]
                      )
                      (lineageSummary rows)
                  other -> assertFailure ("getDelegationChildren should return rows, got " <> show (first (const ("store-error" :: String)) other))
        ],
      testGroup
        "Approval"
        [ testCase "approved answer resumes and dispatches sink once" do
            withShikigamiMigratedDatabase \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                aidRef <- newIORef Nothing
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
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
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
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
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
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
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
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

parentDelegateWorkflow :: SessionId -> Eff (Workflow : AppEffects) Value
parentDelegateWorkflow currentSession = do
  delegated <-
    delegate
      DelegateCtx
        { delegateDepth = 0,
          sessionId = Just (idText currentSession),
          parentSessionId = Nothing,
          parentRunWorkflowId = Nothing
        }
      "heartbeat"
      (object ["source" .= ("delegate-test" :: Text)])
  awaitDelegated delegated

testDeps :: AppEnv -> BehaviorEnv -> AgentRunHooks -> AgentRunDeps
testDeps appEnv behaviorEnv hooks =
  testDepsWithApproval appEnv behaviorEnv hooks defaultApprovalEnv

testDepsWithAgents :: AppEnv -> BehaviorEnv -> AgentRunHooks -> [AgentDecl] -> AgentRunDeps
testDepsWithAgents appEnv behaviorEnv hooks agentDecls =
  AgentRunDeps
    { appEnv,
      behaviorEnv,
      agents = agentDecls,
      kizashi = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "recipient"},
      kawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = "shinzui/shikigami"},
      danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_test"},
      rei = ReiConfig {baseUrl = Nothing},
      hooks,
      approval = defaultApprovalEnv,
      deadline = Nothing,
      logger = Log.silentLogger,
      grants = StaticGrants defaultGrantTable
    }

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
      rei = ReiConfig {baseUrl = Nothing},
      hooks,
      approval,
      deadline,
      logger = Log.silentLogger,
      grants = StaticGrants defaultGrantTable
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

loadProofAgents :: IO [AgentDecl]
loadProofAgents = do
  results <-
    traverse
      loadAgent
      [ "../agents/proof/research-supervisor.dhall",
        "../agents/proof/web-researcher.dhall",
        "../agents/proof/code-researcher.dhall"
      ]
  case sequence results of
    Right loaded -> pure loaded
    Left err -> assertFailure ("proof agents should load: " <> show err)

assertChildCompleted :: String -> Either err (WorkflowOutcome (Either Text AgentRunResult)) -> IO ()
assertChildCompleted label = \case
  Right (Completed (Right _)) -> pure ()
  other -> assertFailure (label <> ", got " <> show (first (const ("store-error" :: String)) other))

lineageSummary :: [SessionRow] -> Set.Set (Text, Maybe Text, Int)
lineageSummary rows =
  Set.fromList
    [ (agentId, parentSessionId, delegationDepth)
    | SessionRow {agentId, parentSessionId, delegationDepth} <- rows
    ]

childLinkSummary :: [ChildRow] -> Set.Set (Text, Text, Text)
childLinkSummary rows =
  Set.fromList
    [ (childName, childId, childStatusText status)
    | ChildRow {childName, childId, status} <- rows
    ]

childStatusText :: ChildStatus -> Text
childStatusText = \case
  Running -> "running"
  ChildCompleted -> "completed"
  ChildCancelled -> "cancelled"
  ChildFailed -> "failed"

turnRoleIndex :: TurnRow -> (Text, Int)
turnRoleIndex TurnRow {role, turnIndex} = (role, turnIndex)

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

flowDecl :: AgentDecl
flowDecl =
  AgentDecl
    { name = "at-risk-customer",
      description = "workflow flow test agent",
      trigger = Event {eventType = "test"},
      behavior = Flow {name = "at-risk-customer"},
      sinks = []
    }

conversationDecl :: AgentDecl
conversationDecl =
  decl
    { trigger = Event {eventType = addressedMessageEventType},
      sinks = [DanwaConversation {topic = "support"}]
    }

firstAddressedMessage :: AddressedMessage
firstAddressedMessage =
  AddressedMessage
    { conversationId = "conv_thread_1",
      messageId = "msg_human_1",
      parentMessageId = Nothing,
      author = "part_human_test",
      content = "first question",
      agentParticipantId = "part_agent_test",
      embellishmentId = "emb_human_1",
      mentionedBy = "part_human_test",
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0
    }

secondAddressedMessage :: AddressedMessage
secondAddressedMessage =
  AddressedMessage
    { conversationId = "conv_thread_1",
      messageId = "msg_human_2",
      parentMessageId = Just "msg_human_1",
      author = "part_human_test",
      content = "follow up",
      agentParticipantId = "part_agent_test",
      embellishmentId = "emb_human_2",
      mentionedBy = "part_human_test",
      occurredAt = UTCTime (fromGregorian 2026 6 27) 1
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

recordBeforeCompleteCrashJob :: RunJob
recordBeforeCompleteCrashJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-record-before-complete-crash",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

flowJob :: RunJob
flowJob =
  RunJob
    { agentName = "at-risk-customer",
      triggerKind = TriggeredByEvent,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object ["text" .= ("customer says thanks, all good" :: Text)],
      idempotencyKey = "at-risk-customer:test-flow-low",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

-- | The same agent and the same calm text as 'flowJob', under a different run
-- id so it gets its own workflow and its own subject.
flowMemoryJob :: RunJob
flowMemoryJob =
  RunJob
    { agentName = "at-risk-customer",
      triggerKind = TriggeredByEvent,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object ["text" .= ("customer says thanks, all good" :: Text)],
      idempotencyKey = "at-risk-customer:test-flow-memory-high",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

-- | Seed the at-risk-customer agent's memory with an escalation on this
-- subject, the way an earlier run of the flow would have
-- ('Shikigami.Flow.AtRiskCustomer.escalatedNote' is worded the same).
recordPriorEscalation :: AppEnv -> Text -> IO ()
recordPriorEscalation appEnv ticket = do
  mid <- genMemoryId
  recordedAt <- getCurrentTime
  result <-
    runAppIO appEnv $
      Memory.record
        RecordMemoryData
          { memoryId = mid,
            agentId = "at-risk-customer",
            sessionId = Nothing,
            scope = agentScope "at-risk-customer",
            memoryType = MemoryPattern,
            content = ticket <> " escalated after acknowledgement timeout",
            priority = 100,
            confidence = MediumConfidence,
            tags = Set.fromList ["flow", "Flow"],
            supersedes = Nothing,
            recordedAt
          }
  case result of
    Right (Right _) -> pure ()
    other -> assertFailure ("seeding the prior escalation should succeed, got " <> show other)

expectedFlowOutput :: Value
expectedFlowOutput =
  object
    [ "level" .= ("low" :: Text),
      "rationale" .= ("no high-risk signal detected" :: Text),
      "ticketId" .= ("at-risk-customer:test-flow-low" :: Text)
    ]

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

researchSupervisorJob :: RunJob
researchSupervisorJob =
  RunJob
    { agentName = "research-supervisor",
      triggerKind = TriggeredByEvent,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object ["topic" .= ("durable workflows" :: Text)],
      idempotencyKey = "research-supervisor:test-fanout",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

expectedSupervisorOutput :: Value
expectedSupervisorOutput =
  object
    [ "summary" .= ("research-supervisor synthesized delegated findings" :: Text),
      "web"
        .= object
          [ "agent" .= ("web-researcher" :: Text),
            "finding" .= ("Web sources indicate durable workflow delegation should journal child waits." :: Text)
          ],
      "code"
        .= object
          [ "agent" .= ("code-researcher" :: Text),
            "finding" .= ("The code path should spawn child workflows before awaiting their results." :: Text)
          ]
    ]
