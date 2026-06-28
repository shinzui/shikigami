module Shikigami.FlowLifecycleSpec (tests) where

import Data.Aeson (Value (String), object, toJSON)
import Data.Text qualified as Text
import Effectful (Eff, runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), runWorkflow, step)
import Keiro.Workflow.Sleep (sleepNamed)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (runStorePool)
import Kiroku.Store.Error (StoreError)
import Shikigami.Flow (FlowDef (..), FlowEffects, LifecycleDiagram (..), atRiskCustomerLifecycleDiagram, lookupFlow)
import Shikigami.Flow.Lifecycle.AtRiskCustomer
  ( atRiskCustomerMermaid,
    atRiskCustomerValidationWarnings,
  )
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
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
        assertEqual "sleeping flow suspends" (Right Suspended) outcome
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
runFlowWorkflow FlowDef {run} workflowId =
  withShikigamiMigratedDatabase \connStr ->
    withStore (defaultConnectionSettings connStr) \kirokuStore ->
      runEff
        . runErrorNoCallStack
        . runStorePool kirokuStore
        $ runWorkflow
          (WorkflowName "shikigami.flow.spike")
          workflowId
          (run (object []))
