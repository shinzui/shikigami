-- | A flow body that runs two coding-agent steps under two keys: each key is
-- its own child workflow, and a replay reads both outcomes without another
-- attempt. This is the representative shape of a playbook's agent steps.
module Shikigami.CodingAgentFlowSpec (tests) where

import Data.Aeson (Value (..), toJSON)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Effectful (Eff)
import Keiro.Workflow (Workflow, WorkflowId (..), WorkflowName (..), runWorkflowWith)
import Keiro.Workflow qualified as Keiro
import Keiro.Workflow.Child (runChildWorkflow)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.CodingAgent.Types
import Shikigami.CodingAgent.Workflow
import Shikigami.Flow.CodingAgent
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Process.Attempt (AttemptResult (..))
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "coding-agent flow capability"
    [ testCase "a flow runs two keyed coding-agent steps and replays them without another attempt" $
        withShikigamiFreshDatabase databaseFixture \connStr ->
          withStore (defaultConnectionSettings connStr) \_ -> do
            tracer <- noopTracer
            attempts <- newIORef []
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                runners = fixedCodingAgentRunner (countingRunner attempts)
                parent = runAppIO appEnv (runWorkflowWith (shikigamiWorkflowRunOptions appEnv) (WorkflowName "shikigami.flow.spike") parentId twoSteps)
                drive key = runAppIO appEnv (runChildWorkflow (shikigamiWorkflowRunOptions appEnv) codingAgentStepWorkflowName (codingAgentChildId parentId.unWorkflowId 0 (codingAgentKey key)) (codingAgentStepWorkflow runners Nothing))
                completedLabel = \case
                  Right (Keiro.Completed outcome) -> pure (outcomeLabel outcome)
                  other -> assertFailure ("the child did not complete: " <> show (fmap (const ()) <$> other))
            parent >>= suspended
            drive "first" >>= completedLabel >>= (@?= "completed")
            parent >>= suspended
            drive "second" >>= completedLabel >>= (@?= "completed")
            finished <- parent
            replayed <- parent
            case (finished, replayed) of
              (Right (Keiro.Completed one), Right (Keiro.Completed two)) -> do
                one @?= toJSON ["completed" :: Text, "completed"]
                two @?= one
              other -> assertFailure ("the flow did not complete: " <> show (fmap (const ()) <$> fst other))
            _ <- drive "first"
            _ <- drive "second"
            readIORef attempts >>= (@?= ["first-attempt", "second-attempt"])
    ]
  where
    parentId = WorkflowId "coding-agent-flow-fixture"
    suspended = \case
      Right Keiro.Suspended -> pure ()
      other -> assertFailure ("expected the flow to await its child, got " <> show (fmap (const ()) <$> other))

twoSteps :: Eff (Workflow : AppEffects) Value
twoSteps =
  runCodingAgent CodingAgentEnv {agent = fixtureAgentName "coding-flow", identity = compatibilityIdentity (fixtureAgentName "coding-flow"), repository = Just "mori://test/repo", tools = []} do
    first' <- runCodingAgentStep (codingAgentKey "first") sampleStep Null
    second' <- runCodingAgentStep (codingAgentKey "second") sampleStep Null
    pure (toJSON [outcomeLabel first', outcomeLabel second'])

-- | A runner that records each attempt by its child's key and launches nothing.
countingRunner :: IORef [Text] -> CodingAgentRunner
countingRunner attempts =
  CodingAgentRunner
    { admit = \CodingAgentStepInput {key, step, parent, generation} -> do
        now <- getCurrentTime
        let childId = codingAgentChildId parent generation key
        pure
          ( Right
              CodingAgentAdmission
                { step,
                  child = childId.unWorkflowId,
                  repository = "mori://test/repo",
                  root = "/nonexistent",
                  branch = "fixture",
                  base = "0000000",
                  deadline = addUTCTime 60 now,
                  attemptDirectory = "/nonexistent",
                  skills = [],
                  providerArgs = [],
                  toolLines = []
                }
          ),
      attempt = \admission -> do
        let label = if ":first" `Text.isSuffixOf` admission.child then "first-attempt" else "second-attempt"
        atomicModifyIORef' attempts (\seen -> (seen <> [label], ()))
        pure (Collected Null),
      settle = \_ _ -> pure (Completed CompletedRun {exit = 0, changes = ChangeSummary [] 0, result = Unchanged "0000000", finalMessage = "done", evidence = Nothing})
    }

sampleStep :: CodingAgentStep
sampleStep =
  CodingAgentStep
    { provider = ClaudeCode,
      prompt = either (error . show) id (mkCodingAgentPrompt "Change nothing."),
      access = ReadOnly,
      model = Nothing,
      effort = Nothing,
      deadlineMinutes = either (error . show) id (mkDeadlineMinutes 5),
      skills = []
    }

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName
