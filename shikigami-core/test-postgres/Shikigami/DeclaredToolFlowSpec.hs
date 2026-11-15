-- | A flow body that runs two declared-tool steps under two keys: each key is
-- its own child workflow, and a replay reads both outcomes without another
-- attempt (EP-3 M4 of MasterPlan 22).
module Shikigami.DeclaredToolFlowSpec (tests) where

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
import Shikigami.Capability.Declared (mkToolName)
import Shikigami.DeclaredTool.Workflow
import Shikigami.Flow.DeclaredTool
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Process.Attempt (AttemptResult (..))
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "declared-tool flow capability"
    [ testCase "a flow runs two keyed declared-tool steps and replays them without another attempt" $
        withShikigamiFreshDatabase databaseFixture \connStr ->
          withStore (defaultConnectionSettings connStr) \_ -> do
            tracer <- noopTracer
            attempts <- newIORef []
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                runners _ = pure (Right (countingRunner attempts))
                parent = runAppIO appEnv (runWorkflowWith (shikigamiWorkflowRunOptions appEnv) (WorkflowName "shikigami.flow.spike") parentId twoSteps)
                drive key = runAppIO appEnv (runChildWorkflow (shikigamiWorkflowRunOptions appEnv) declaredToolStepWorkflowName (declaredToolChildId parentId.unWorkflowId 0 (toolStepKey key)) (declaredToolStepWorkflow runners Nothing))
                completed = \case
                  Right (Keiro.Completed outcome) -> pure (toolStepOutcomeLabel outcome)
                  other -> assertFailure ("the child did not complete: " <> show (fmap (const ()) <$> other))
            parent >>= suspended
            drive "build" >>= completed >>= (@?= "completed")
            parent >>= suspended
            drive "test" >>= completed >>= (@?= "completed")
            finished <- parent
            replayed <- parent
            case (finished, replayed) of
              (Right (Keiro.Completed one), Right (Keiro.Completed two)) -> do
                one @?= toJSON ["completed" :: Text, "completed"]
                two @?= one
              other -> assertFailure ("the flow did not complete: " <> show (fmap (const ()) <$> fst other))
            _ <- drive "build"
            _ <- drive "test"
            readIORef attempts >>= (@?= ["build", "test"])
    ]
  where
    parentId = WorkflowId "declared-tool-flow-fixture"
    suspended = \case
      Right Keiro.Suspended -> pure ()
      other -> assertFailure ("expected the flow to await its child, got " <> show (fmap (const ()) <$> other))

twoSteps :: Eff (Workflow : AppEffects) Value
twoSteps =
  runDeclaredToolCapability DeclaredToolEnv {agent = fixtureAgentName "build-flow", identity = compatibilityIdentity (fixtureAgentName "build-flow"), tools = [], repository = Nothing} do
    build <- runDeclaredTool (toolStepKey "build") (sampleStep ["build"])
    test <- runDeclaredTool (toolStepKey "test") (sampleStep ["test"])
    pure (toJSON [toolStepOutcomeLabel build, toolStepOutcomeLabel test])

-- | Records each attempt by its first argument and launches nothing.
countingRunner :: IORef [Text] -> DeclaredToolRunner
countingRunner attempts =
  DeclaredToolRunner
    { admit = \input@DeclaredToolStepInput {step} -> do
        now <- getCurrentTime
        pure (Right DeclaredToolAdmission {child = (declaredToolStepWorkflowId input).unWorkflowId, tool = "cli.cabal", program = "/bin/true", arguments = step.arguments, root = "/nonexistent", deadline = addUTCTime 60 now, outputLimit = 1024, attemptDirectory = "/nonexistent"}),
      attempt = \admission -> do
        atomicModifyIORef' attempts (\seen -> (seen <> take 1 admission.arguments, ()))
        pure (Collected Null),
      settle = \_ _ -> pure (ToolCompleted ToolRun {exit = 0, stdout = "", stderr = "", droppedBytes = 0, elapsedMs = 1})
    }

sampleStep :: [Text] -> ToolStep
sampleStep arguments = either (error . Text.unpack) id (mkToolName "cabal" >>= \tool -> mkToolStep tool arguments 5)

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName
