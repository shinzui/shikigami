module Shikigami.DelegateContextSpec (tests) where

import Data.Foldable (traverse_)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..), DelegationError (..), checkDepth)
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
          (checkDepth (ctxAt 4))
    ]

ctxAt :: Int -> DelegateCtx
ctxAt depth =
  DelegateCtx
    { delegateDepth = depth,
      sessionId = Nothing,
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing
    }

assertAccepted :: (Int, Int) -> IO ()
assertAccepted (current, expectedChild) =
  assertEqual
    ("depth " <> show current <> " creates child depth " <> show expectedChild)
    (Right (ctxAt expectedChild))
    (checkDepth (ctxAt current))
