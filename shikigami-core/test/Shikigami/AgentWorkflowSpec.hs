module Shikigami.AgentWorkflowSpec (tests) where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.Aeson (object)
import Data.Bifunctor (first)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Keiro.Outbox (listOutbox)
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowOutcome (..), completedStepName, loadStepIndex)
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.Workflow (AgentRunDeps (..), AgentRunHooks (..), agentRunWorkflowName, defaultAgentRunHooks, runAgentRunWorkflow)
import Shikigami.Api.Agent (AgentDecl (..), Behavior (..), Sink (..), Trigger (..))
import Shikigami.Api.RunJob (RunJob (..), TriggerKind (..))
import Shikigami.Behavior.Run (BehaviorEnv, newBehaviorEnv)
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.Sink.Config (KawaConfig (..), KizashiConfig (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

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
                assertEqual "open-session replayed the original session id" (runSessionId firstResult) (runSessionId secondResult)
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
            assertEqual "recovered run enqueued one stable outbox row" (Right 1) (length <$> outboxRows)
    ]

testDeps :: AppEnv -> BehaviorEnv -> AgentRunHooks -> AgentRunDeps
testDeps appEnv behaviorEnv hooks =
  AgentRunDeps
    { appEnv,
      behaviorEnv,
      agents = [decl],
      kizashi = KizashiConfig {kizashiBaseUrl = "http://localhost:1", kizashiDefaultRecipient = "recipient"},
      kawa = KawaConfig {kawaBaseUrl = "http://localhost:1", kawaSourceSegment = "shinzui/shikigami"},
      hooks
    }

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
      idempotencyKey = "heartbeat:test-workflow-replay"
    }

crashJob :: RunJob
crashJob =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:test-workflow-crash-resume"
    }
