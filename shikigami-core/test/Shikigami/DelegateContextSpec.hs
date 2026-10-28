module Shikigami.DelegateContextSpec (tests) where

import Data.Foldable (traverse_)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Trigger (..), defaultDelegationBudget, defaultMemoryPolicy)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..), DelegationError (..), assertMayDelegate, checkCycle, checkDepth)
import Shikigami.Agent.Delegate.Depth (DelegationDepth (..))
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (compatibilityIdentity)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Delegate.Context"
    [ testCase "checkDepth admits child depths 1 through 3" do
        traverse_
          assertAccepted
          [ (0, 1),
            (1, 2),
            (2, 3)
          ],
      testCase "checkDepth rejects attempted depth 4" do
        assertEqual
          "depth 3 cannot create a depth-4 child"
          (Left (DelegationDepthExceeded 4))
          (checkDepth (ctxAt 3)),
      testCase "checkDepth rejects deeper attempts with attempted depth" do
        assertEqual
          "the error reports the attempted child depth"
          (Left (DelegationDepthExceeded 5))
          (checkDepth (ctxAt 4)),
      testCase "a maximal wire depth cannot overflow into an admitted child" do
        assertEqual
          "depth arithmetic does not wrap"
          (Left (DelegationDepthExceeded (toInteger (maxBound :: Int) + 1)))
          (checkDepth (ctxAt maxBound)),
      testCase "allow-list refuses undeclared targets" do
        assertEqual "declared target is admitted" (Right ()) (assertMayDelegate delegatingAgent "worker")
        assertEqual "undeclared target is refused" (Left (DelegationNotAllowed "intruder")) (assertMayDelegate delegatingAgent "intruder"),
      testCase "cycle detection checks the complete ancestor chain" do
        assertEqual "an ancestor is refused" (Left (DelegationCycleDetected "root")) (checkCycle (ctxAt 0) "root")
        assertEqual "a new descendant is admitted" (Right ()) (checkCycle (ctxAt 0) "worker")
    ]

ctxAt :: Int -> DelegateCtx
ctxAt depth =
  DelegateCtx
    { identity = compatibilityIdentity "lead",
      depth = DelegationDepth depth,
      sessionId = Nothing,
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      lineage = map AgentName ["root", "lead"],
      executionRootId = Nothing,
      delegationBudgetId = Nothing,
      budgetLimit = defaultDelegationBudget
    }

delegatingAgent :: AgentDecl
delegatingAgent =
  AgentDecl
    { name = "lead",
      description = "delegation guard fixture",
      trigger = Event {eventType = "test"},
      behavior = Deterministic {rule = "test", params = mempty},
      sinks = [],
      delegates = ["worker"],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [],
      decisionModels = [],
      routing = Nothing
    }

assertAccepted :: (Int, Int) -> IO ()
assertAccepted (current, expectedChild) =
  assertEqual
    ("depth " <> show current <> " creates child depth " <> show expectedChild)
    (Right (ctxAt expectedChild))
    (checkDepth (ctxAt current))
