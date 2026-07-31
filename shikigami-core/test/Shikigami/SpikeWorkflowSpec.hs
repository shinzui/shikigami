module Shikigami.SpikeWorkflowSpec (tests) where

import Control.Exception (SomeException, try)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), runWorkflow, step)
import Kioku.App (AppEnv (..), noopTracer)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (runStoreResource)
import Kiroku.Store.Effect.Resource (withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Spike"
    [ testCase "replays the first step after a crash" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer = tracer, metrics = Nothing}
            counter <- newIORef (0 :: Int)
            shouldCrash <- newIORef True

            first <- try (runSpikeWorkflow appEnv counter shouldCrash)
            case first of
              Left (_ :: SomeException) -> pure ()
              Right other -> assertBool ("expected first workflow run to crash, got " <> show other) False

            afterCrash <- readIORef counter
            assertEqual "step one ran before the simulated crash" 1 afterCrash

            second <- runSpikeWorkflow appEnv counter shouldCrash
            assertEqual "workflow completes on the second run" (Right (Completed "two")) second

            final <- readIORef counter
            assertEqual "step one was replayed from the journal, not re-run" 1 final
    ]

runSpikeWorkflow ::
  AppEnv ->
  IORef Int ->
  IORef Bool ->
  IO (Either StoreError (WorkflowOutcome Text))
runSpikeWorkflow appEnv counter shouldCrash =
  runEff
    . runErrorNoCallStack
    . withKirokuStore (connectionSettings appEnv)
    . runStoreResource
    $ runWorkflow
      (WorkflowName "shikigami.spike")
      (WorkflowId "spike-replay")
      (spikeWorkflow counter shouldCrash)

spikeWorkflow ::
  (Workflow :> es, IOE :> es) =>
  IORef Int ->
  IORef Bool ->
  Eff es Text
spikeWorkflow counter shouldCrash = do
  _one <-
    step (StepName "one") do
      liftIO (modifyIORef' counter (+ 1))
      pure ("one" :: Text)
  crashNow <- liftIO do
    current <- readIORef shouldCrash
    if current
      then do
        modifyIORef' shouldCrash (const False)
        pure True
      else pure False
  if crashNow
    then liftIO (ioError (userError "simulated crash after step one"))
    else step (StepName "two") (pure ("two" :: Text))
