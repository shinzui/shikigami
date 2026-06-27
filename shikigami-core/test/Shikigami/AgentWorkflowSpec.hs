module Shikigami.AgentWorkflowSpec (tests) where

import Data.Aeson (object)
import Data.Time (UTCTime (..), fromGregorian)
import Keiro.Outbox (listOutbox)
import Keiro.Workflow (WorkflowOutcome (..))
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.Workflow (AgentRunDeps (..), runAgentRunWorkflow)
import Shikigami.Api.Agent (AgentDecl (..), Behavior (..), Sink (..), Trigger (..))
import Shikigami.Api.RunJob (RunJob (..), TriggerKind (..))
import Shikigami.Behavior.Run (newBehaviorEnv)
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
                deps =
                  AgentRunDeps
                    { appEnv,
                      behaviorEnv,
                      agents = [decl],
                      kizashi = KizashiConfig {kizashiBaseUrl = "http://localhost:1", kizashiDefaultRecipient = "recipient"},
                      kawa = KawaConfig {kawaBaseUrl = "http://localhost:1", kawaSourceSegment = "shinzui/shikigami"}
                    }

            first <- runAgentRunWorkflow deps job
            second <- runAgentRunWorkflow deps job
            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")

            case (first, second) of
              (Right (Completed (Right firstResult)), Right (Completed (Right secondResult))) -> do
                assertEqual "open-session replayed the original session id" (runSessionId firstResult) (runSessionId secondResult)
                assertEqual "dispatch-sinks enqueued one stable outbox row" (Right 1) (length <$> outboxRows)
              other -> assertEqual "both workflow runs complete successfully" "completed twice" (show other)
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
