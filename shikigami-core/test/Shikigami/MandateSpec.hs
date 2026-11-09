module Shikigami.MandateSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Either (isLeft)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Shikigami.Mandate.Types
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "Mandate"
    [ testCase "positive bounded cadence and finite expiry are mandatory" do
        assertBool "zero cadence" (isLeft (validateSchedule now (Cadence 0 10) later))
        assertBool "unbounded cadence" (isLeft (validateSchedule now (Cadence 1 maxBound) later))
        assertBool "inverted cadence" (isLeft (validateSchedule now (Cadence 10 1) later))
        assertBool "expired authority" (isLeft (validateSchedule now (Cadence 1 8) now))
        assertBool "indefinite expiry" (isLeft (validateSchedule now (Cadence 1 8) (addUTCTime (367 * 86400) now)))
        validateSchedule now (Cadence 1 8) later @?= Right (),
      testCase "backoff is bounded even after many idle cycles" do
        map (backoff (Cadence 2 10)) [0, 1, 2, 3, 1000000] @?= [2, 4, 8, 10, 10],
      testCase "command JSON refuses undeclared fields and invalid mandate identities" do
        Aeson.toJSON CurrentObjectiveCheckpoint @?= Aeson.String "CurrentObjectiveCheckpoint"
        assertBool "extra schedule field" (case Aeson.fromJSON @Cadence (Aeson.object ["seconds" .= (1 :: Int), "maximumSeconds" .= (8 :: Int), "authority" .= True]) of Aeson.Error _ -> True; _ -> False)
        assertBool "empty id" (isLeft (parseMandateId ""))
        assertBool "unbounded id" (isLeft (parseMandateId (Text.replicate 161 "a")))
        assertBool "path traversal" (isLeft (parseMandateId "../../other"))
    ]
  where
    now = UTCTime (fromGregorian 2026 11 8) 0
    later = addUTCTime 600 now
