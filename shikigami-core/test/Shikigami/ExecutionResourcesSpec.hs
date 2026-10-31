module Shikigami.ExecutionResourcesSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), fromGregorian)
import Shikigami.Execution.Quantity (ResourceAmount, parseResourceAmount)
import Shikigami.Execution.Resources
import Shikigami.StateRevision (initialRevision)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "ExecutionResources"
    [ testCase "root revisions preserve numeric JSON and reject negative admission" do
        let now = UTCTime (fromGregorian 2026 10 30) 0
            root = Root (Envelope Map.empty now) initialRevision False Nothing False 0 0 Map.empty emptyUsage
            encoded = Aeson.toJSON root
        Aeson.fromJSON encoded @?= Aeson.Success root
        case encoded of
          Aeson.Object fields -> do
            fmap Aeson.encode (KeyMap.lookup "revision" fields) @?= Just (Aeson.encode (0 :: Integer))
            let negative = Aeson.Object (KeyMap.insert "revision" (Aeson.toJSON (-1 :: Integer)) fields)
            assertBool "negative root revision refused" (case Aeson.fromJSON negative :: Aeson.Result Root of Aeson.Error _ -> True; _ -> False)
          _ -> assertFailure "resource root was not an object",
      testCase "negative and overflowing quantities are refused" do
        mapM_
          (\n -> assertBool "invalid integer refused" (case parseResourceAmount n of Left _ -> True; _ -> False))
          [-1, toInteger (maxBound :: Int64) + 1],
      testCase "amount and finite-limit codecs preserve primitive numeric bytes" do
        mapM_
          ( \number -> do
              let amount = fixtureAmount number
              Aeson.fromJSON (Aeson.toJSON amount) @?= Aeson.Success amount
              Aeson.encode amount @?= Aeson.encode number
          )
          [0, 1, toInteger (maxBound :: Int64)]
        let limit = Limited (fixtureAmount 7)
        Aeson.fromJSON (Aeson.toJSON limit) @?= Aeson.Success limit
        Aeson.toJSON limit @?= Aeson.object ["tag" .= ("Limited" :: String), "contents" .= (7 :: Integer)]
        mapM_
          ( \number -> case Aeson.fromJSON (Aeson.toJSON number) :: Aeson.Result ResourceAmount of
              Aeson.Error _ -> pure ()
              Aeson.Success _ -> assertFailure "invalid amount decoded"
          )
          [-1, toInteger (maxBound :: Int64) + 1],
      testCase "checked vector subtraction retains zero and refuses underflow" do
        let one = Map.singleton Tokens (fixtureAmount 1)
        subtractAmounts one one @?= Right (Map.singleton Tokens (fixtureAmount 0))
        assertBool "negative debit refused" (case subtractAmounts Map.empty one of Left _ -> True; Right _ -> False),
      testCase "dimension and finite-limit refusal precede aggregate overflow" do
        let usage = Usage (Map.singleton Tokens (fixtureAmount (toInteger (maxBound :: Int64)))) Map.empty
            request = Map.singleton Tokens (fixtureAmount 1)
        admit Map.empty usage request @?= Left (DimensionNotAdmitted Tokens)
        admit (Map.singleton Tokens (Limited (fixtureAmount 1))) usage request @?= Left (ResourceExhausted Tokens),
      testCase "aggregate arithmetic cannot overflow a bounded unit" do
        let top = toInteger (maxBound :: Int64)
        assertBool "sum refused before int64 overflow" (case admit (Map.singleton Tokens ExplicitlyUnbounded) (Usage (Map.singleton Tokens (fixtureAmount top)) Map.empty) (Map.singleton Tokens (fixtureAmount 1)) of Left _ -> True; _ -> False),
      testCase "completion cannot erase an unreported reserved dimension" do
        let amounts = Map.fromList [(ActiveWork, (fixtureAmount 1)), (ModelAttempts, (fixtureAmount 1)), (Tokens, (fixtureAmount 10)), (CostMicroUsd, (fixtureAmount 1000))]
        assertBool "cost cannot silently become zero" (case settleUsage amounts (Map.singleton Tokens (fixtureAmount 2)) (Usage Map.empty amounts) of Left _ -> True; _ -> False),
      testCase "actual attempt counters cannot be refunded through measurements" do
        let amounts = Map.fromList [(ActiveWork, (fixtureAmount 1)), (ModelAttempts, (fixtureAmount 1))]
        assertBool "caller cannot supply an attempt refund" (case settleUsage amounts (Map.singleton ModelAttempts (fixtureAmount 0)) (Usage Map.empty amounts) of Left _ -> True; _ -> False)
    ]

fixtureAmount :: Integer -> ResourceAmount
fixtureAmount amount = either (error . show) id (parseResourceAmount amount)
