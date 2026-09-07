module Main (main) where

import Data.Text qualified as Text
import Keiki.Acceptor qualified as Acceptor
import Shikigami.Flow (LifecycleDiagram (..), atRiskCustomerLifecycleDiagram)
import Shikigami.Flow.Lifecycle.AtRiskCustomer (AtRiskCustomerCommand (..), atRiskCustomerLifecycle, atRiskCustomerMermaid, atRiskCustomerValidationWarnings)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

main :: IO ()
main =
  defaultMain $
    testGroup
      "lifecycle diagrams"
      [ testCase "at-risk customer lifecycle is well-formed" do
          assertEqual "keiki validation warnings" [] atRiskCustomerValidationWarnings,
        testCase "at-risk flow branches belong to the lifecycle command language" do
          let accepts = Acceptor.accepts (Acceptor.inputAcceptor atRiskCustomerLifecycle)
          assertBool "low-risk branch is accepted" (accepts [ClassifyLowRisk])
          assertBool "acknowledged high-risk branch is accepted" (accepts [ClassifyHighRisk, Acknowledge])
          assertBool "timed-out high-risk branch is accepted" (accepts [ClassifyHighRisk, DeadlineExpired])
          assertBool "acknowledgement cannot precede classification" (not (accepts [Acknowledge])),
        testCase "at-risk customer lifecycle renders the expected states" do
          assertBool "Mermaid output starts as a state diagram" ("stateDiagram-v2" `Text.isInfixOf` atRiskCustomerMermaid)
          assertBool "Mermaid output includes AwaitingAck" ("AwaitingAck" `Text.isInfixOf` atRiskCustomerMermaid)
          assertBool "Mermaid output includes Escalated" ("Escalated" `Text.isInfixOf` atRiskCustomerMermaid),
        testCase "at-risk customer lifecycle is available as a registry diagram" do
          let LifecycleDiagram {mermaid, validationWarnings} = atRiskCustomerLifecycleDiagram
          assertEqual "registry diagram has no validation warnings" [] validationWarnings
          assertBool "registry diagram includes AwaitingAck" ("AwaitingAck" `Text.isInfixOf` mermaid)
      ]
