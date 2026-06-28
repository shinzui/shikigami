module Shikigami.FlowLifecycleSpec (tests) where

import Data.Text qualified as Text
import Shikigami.Flow.Lifecycle.AtRiskCustomer
  ( atRiskCustomerMermaid,
    atRiskCustomerValidationWarnings,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "FlowLifecycle"
    [ testCase "at-risk customer lifecycle is well-formed" do
        assertEqual "keiki validation warnings" [] atRiskCustomerValidationWarnings,
      testCase "at-risk customer lifecycle renders the expected states" do
        assertBool "Mermaid output starts as a state diagram" ("stateDiagram-v2" `Text.isInfixOf` atRiskCustomerMermaid)
        assertBool "Mermaid output includes AwaitingAck" ("AwaitingAck" `Text.isInfixOf` atRiskCustomerMermaid)
        assertBool "Mermaid output includes Escalated" ("Escalated" `Text.isInfixOf` atRiskCustomerMermaid)
    ]
