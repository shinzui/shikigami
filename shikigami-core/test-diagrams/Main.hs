module Main (main) where

import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Keiki.Acceptor qualified as Acceptor
import Keiki.Render.Validate (MermaidValidationOptions (..), defaultMermaidValidationOptions, validateMermaidAtlas)
import Shikigami.Diagrams (domainAtlas, domainEdgeInspectors)
import Shikigami.Flow (LifecycleDiagram (..), atRiskCustomerLifecycleDiagram)
import Shikigami.Flow.Lifecycle.AtRiskCustomer (AtRiskCustomerCommand (..), atRiskCustomerLifecycle, atRiskCustomerMermaid, atRiskCustomerValidationWarnings)
import System.Environment (getArgs, withArgs)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--write-atlas"] -> do
      Text.writeFile "../docs/architecture/domain-atlas.md" domainAtlas
      Text.writeFile "../docs/architecture/domain-edge-inspectors.md" domainEdgeInspectors
    _ -> withArgs args tests

tests :: IO ()
tests =
  defaultMain $
    testGroup
      "lifecycle diagrams"
      [ testCase "the complete atlas passes readable Mermaid validation" do
          assertEqual "Mermaid findings" [] (validateMermaidAtlas defaultMermaidValidationOptions {maxLabelLength = Nothing, suspiciousChars = ['\"', '{', '}']} domainAtlas),
        testCase "checked-in diagrams match executable transducers" do
          atlas <- Text.readFile "../docs/architecture/domain-atlas.md"
          inspectors <- Text.readFile "../docs/architecture/domain-edge-inspectors.md"
          assertEqual "atlas drift; run just domain-diagrams" domainAtlas atlas
          assertEqual "edge inspector drift; run just domain-diagrams" domainEdgeInspectors inspectors,
        testCase "at-risk customer lifecycle is well-formed" do
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
