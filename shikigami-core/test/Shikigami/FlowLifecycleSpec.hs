module Shikigami.FlowLifecycleSpec (tests) where

import Data.Aeson (Value (Bool, String), object, toJSON, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Keiro.Outbox (listOutbox)
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), runWorkflow, step)
import Keiro.Workflow.Sleep (sleepNamed)
import Kioku.Api.Types (MemoryRecord (..))
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (runStorePool)
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Api.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Api.Agent (AgentDecl (..), Behavior (..), Priority (Normal), RecipientFrom (SubjectOwner), SignalType (Reminder), Sink (..), Trigger (..))
import Shikigami.Flow (FlowDef (..), FlowEffects, LifecycleDiagram (..), atRiskCustomerLifecycleDiagram, lookupFlow)
import Shikigami.Flow.Acknowledgement (Ack (..), ackFromDecision)
import Shikigami.Flow.Capability
  ( MemoryEnv (..),
    MemoryQuery (..),
    SinkEnv (..),
    currentActivity,
    emitSignal,
    recall,
    remember,
    runActivity,
    runMemory,
    runSink,
  )
import Shikigami.Flow.Lifecycle.AtRiskCustomer
  ( atRiskCustomerMermaid,
    atRiskCustomerValidationWarnings,
  )
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.Sink.Permission (SinkKind (SKizashiSignal))
import Shikigami.Sink.Types (SinkOutcome (Delivered, DeniedOutcome), SinkResult (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "FlowLifecycle"
    [ testCase "at-risk customer lifecycle is well-formed" do
        assertEqual "keiki validation warnings" [] atRiskCustomerValidationWarnings,
      testCase "at-risk customer lifecycle renders the expected states" do
        assertBool "Mermaid output starts as a state diagram" ("stateDiagram-v2" `Text.isInfixOf` atRiskCustomerMermaid)
        assertBool "Mermaid output includes AwaitingAck" ("AwaitingAck" `Text.isInfixOf` atRiskCustomerMermaid)
        assertBool "Mermaid output includes Escalated" ("Escalated" `Text.isInfixOf` atRiskCustomerMermaid),
      testCase "at-risk customer lifecycle is available as a registry diagram" do
        let LifecycleDiagram {mermaid, validationWarnings} = atRiskCustomerLifecycleDiagram
        assertEqual "registry diagram has no validation warnings" [] validationWarnings
        assertBool "registry diagram includes AwaitingAck" ("AwaitingAck" `Text.isInfixOf` mermaid),
      testCase "empty flow registry lookup misses unknown flows" do
        case lookupFlow "at-risk-customer" of
          Nothing -> pure ()
          Just flow -> assertFailure ("expected empty registry lookup, got " <> show flow),
      testCase "trivial flow completes through keiro runWorkflow" do
        outcome <- runFlowWorkflow completedFlow (WorkflowId "flow-completed-spike")
        assertEqual "two-step flow completes" (Right (Completed (toJSON (2 :: Int)))) outcome,
      testCase "sleeping flow suspends through keiro runWorkflow" do
        outcome <- runFlowWorkflow sleepingFlow (WorkflowId "flow-sleeping-spike")
        assertEqual "sleeping flow suspends" (Right Suspended) outcome,
      testCase "currentActivity exposes the triggering activity envelope" do
        outcome <- runFlowWorkflow activityFlow (WorkflowId "flow-activity-spike")
        assertEqual "activity id is available to the flow" (Right (Completed (String "act_flow_test"))) outcome,
      testCase "remember and recall use the flow memory capability" do
        outcome <- runFlowWorkflow memoryFlow (WorkflowId "flow-memory-spike")
        assertEqual "recalled memories include the remembered flow note" (Right (Completed (Bool True))) outcome,
      testCase "emitSignal enqueues an allowed sink outbox intent" do
        (outcome, outboxCount) <- runFlowWorkflowWithAgent "at-risk-customer" sinkFlow (WorkflowId "flow-sink-spike")
        assertEqual
          "allowed sink returns a delivered outbox result"
          (Right (Completed (toJSON (SinkResult SKizashiSignal (Delivered "outbox:flow-sink-spike:emit-signal:0")))))
          outcome
        assertEqual "allowed sink enqueues one outbox message" (Right 1) outboxCount,
      testCase "emitSignal records denied sinks without enqueueing" do
        (outcome, outboxCount) <- runFlowWorkflowWithAgent "intruder" sinkFlow (WorkflowId "flow-denied-sink-spike")
        case outcome of
          Right (Completed encodedResult) -> case encodedResult of
            _ | encodedResult == toJSON (SinkResult SKizashiSignal (DeniedOutcome "agent 'intruder' has no sink grants")) -> pure ()
            other -> assertFailure ("expected denied sink result, got " <> show other)
          other -> assertFailure ("denied sink flow should complete, got " <> show other)
        assertEqual "denied sink does not enqueue an outbox message" (Right 0) outboxCount,
      testCase "acknowledgement wrapper maps approval decisions" do
        assertEqual "approved maps to acknowledged" (Acknowledged (toJSON True)) (ackFromDecision (Approval.Approved (toJSON True)))
        assertEqual "rejected maps to declined" (Declined "no") (ackFromDecision (Approval.Rejected "no"))
        assertEqual "timeout maps to timeout" TimedOut (ackFromDecision Approval.TimedOut)
    ]

completedFlow :: FlowDef
completedFlow =
  FlowDef
    { name = "completed-spike",
      lifecycle = atRiskCustomerLifecycleDiagram,
      run = twoStepFlow
    }

sleepingFlow :: FlowDef
sleepingFlow =
  FlowDef
    { name = "sleeping-spike",
      lifecycle = atRiskCustomerLifecycleDiagram,
      run = sleepFlow
    }

activityFlow :: FlowDef
activityFlow =
  FlowDef
    { name = "activity-spike",
      lifecycle = atRiskCustomerLifecycleDiagram,
      run = \_payload -> do
        activity <- currentActivity
        pure (String (activityId activity))
    }

memoryFlow :: FlowDef
memoryFlow =
  FlowDef
    { name = "memory-spike",
      lifecycle = atRiskCustomerLifecycleDiagram,
      run = \_payload -> do
        _ <- remember (object ["summary" .= ("flow durable note" :: Text)])
        memories <- recall (MemoryQuery "flow durable note")
        pure (Bool (any (\MemoryRecord {content} -> content == "flow durable note") memories))
    }

sinkFlow :: FlowDef
sinkFlow =
  FlowDef
    { name = "sink-spike",
      lifecycle = atRiskCustomerLifecycleDiagram,
      run = \_payload -> toJSON <$> emitSignal sampleKizashiSink (object ["summary" .= ("flow alert" :: Text)])
    }

twoStepFlow :: (FlowEffects es) => Value -> Eff es Value
twoStepFlow _payload = do
  _ <- step (StepName "a") (pure (String "a"))
  step (StepName "b") (pure (toJSON (2 :: Int)))

sleepFlow :: (FlowEffects es) => Value -> Eff es Value
sleepFlow _payload = do
  _ <- step (StepName "before-wait") (pure (String "before-wait"))
  sleepNamed (StepName "wait") 300
  pure (String "after-wait")

runFlowWorkflow ::
  FlowDef ->
  WorkflowId ->
  IO (Either StoreError (WorkflowOutcome Value))
runFlowWorkflow flow workflowId =
  fst <$> runFlowWorkflowWithAgent "at-risk-customer" flow workflowId

runFlowWorkflowWithAgent ::
  Text ->
  FlowDef ->
  WorkflowId ->
  IO (Either StoreError (WorkflowOutcome Value), Either StoreError Int)
runFlowWorkflowWithAgent flowAgent FlowDef {run} workflowId =
  withShikigamiMigratedDatabase \connStr ->
    withStore (defaultConnectionSettings connStr) \kirokuStore -> do
      tracer <- noopTracer
      let appEnv = AppEnv {store = kirokuStore, tracer, metrics = Nothing}
          memoryEnv = MemoryEnv {appEnv, agent = flowAgentDecl flowAgent, sessionId = Nothing}
          sinkEnv = SinkEnv {agent = flowAgent, runId = "flow-test-run", occurredAt = Just flowOccurredAt, danwaTarget = Nothing}
          body =
            runActivity sampleActivity
              . runMemory memoryEnv
              . runSink sinkEnv
              $ run (object [])
      outcome <-
        runEff
          . runErrorNoCallStack
          . runStorePool kirokuStore
          $ runWorkflow
            (WorkflowName "shikigami.flow.spike")
            workflowId
            body
      outboxCount <- fmap length <$> runAppIO appEnv (listOutbox "shinzui/shikigami")
      pure (outcome, outboxCount)

sampleActivity :: ActivityEnvelope
sampleActivity =
  ActivityEnvelope
    { activityId = "act_flow_test",
      occurredAt = "2026-06-27T00:00:00Z",
      source = "shinzui/shikigami",
      actor = Actor {kind = "service", id = "flow-test", session = Nothing},
      subject = Subject {subjectType = "customer", subjectId = "cust_1"},
      verb = "customer.risk_detected",
      payload = object [],
      contextRefs = [],
      idempotencyKey = "act_flow_test"
    }

sampleKizashiSink :: Sink
sampleKizashiSink =
  KizashiSignal
    { source = "shinzui/shikigami",
      signalType = Reminder,
      priority = Normal,
      importance = 50,
      recipientFrom = SubjectOwner,
      defaultRecipient = Just "recipient_x",
      intentTemplate = "triage this",
      extraContextTags = ["verb:customer.risk_detected"]
    }

flowAgentDecl :: Text -> AgentDecl
flowAgentDecl flowAgent =
  AgentDecl
    { name = flowAgent,
      description = "flow capability test agent",
      trigger = Event {eventType = "customer.risk_detected"},
      behavior =
        Deterministic
          { rule = "flow-test",
            params = mempty
          },
      sinks = []
    }

flowOccurredAt :: UTCTime
flowOccurredAt = UTCTime (fromGregorian 2026 6 27) 0
