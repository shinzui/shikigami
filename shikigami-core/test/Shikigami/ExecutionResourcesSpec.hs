module Shikigami.ExecutionResourcesSpec (tests) where

import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Shikigami.Execution.Resources
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "ExecutionResources"
    [ testCase "negative and overflowing quantities are refused" do
        mapM_
          (\n -> assertBool "invalid integer refused" (case validateQuantities (Map.singleton Tokens n) of Left _ -> True; _ -> False))
          [-1, toInteger (maxBound :: Int64) + 1],
      testCase "aggregate arithmetic cannot overflow a bounded unit" do
        let top = toInteger (maxBound :: Int64)
        assertBool "sum refused before int64 overflow" (case admit (Map.singleton Tokens ExplicitlyUnbounded) (Usage (Map.singleton Tokens top) Map.empty) (Map.singleton Tokens 1) of Left _ -> True; _ -> False),
      testCase "completion cannot erase an unreported reserved dimension" do
        let amounts = Map.fromList [(ActiveWork, 1), (ModelAttempts, 1), (Tokens, 10), (CostMicroUsd, 1000)]
        assertBool "cost cannot silently become zero" (case settleUsage amounts (Map.singleton Tokens 2) (Usage Map.empty amounts) of Left _ -> True; _ -> False),
      testCase "actual attempt counters cannot be refunded through measurements" do
        let amounts = Map.fromList [(ActiveWork, 1), (ModelAttempts, 1)]
        assertBool "caller cannot supply an attempt refund" (case settleUsage amounts (Map.singleton ModelAttempts 0) (Usage Map.empty amounts) of Left _ -> True; _ -> False)
    ]
