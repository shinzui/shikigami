module Shikigami.AgentRunValueSpec (tests) where

import Data.Aeson (Result (..), Value (..), encode, fromJSON, object, toJSON)
import Data.Either (isLeft)
import Data.Text qualified as Text
import Shikigami.AgentRun.Ledger
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "acceptance ledger values"
    [ testCase "payload fingerprints retain the original UUIDv5 commitment bytes" do
        -- Captured from the compiled pre-change producer, not regenerated from
        -- the new wrapper. This technical commitment allocates no entity.
        mapM_
          ( \(value, expected) -> do
              let fingerprint = payloadFingerprint value
              payloadFingerprintText fingerprint @?= expected
              encode fingerprint @?= encode expected
              parsePayloadFingerprint expected @?= Right fingerprint
              fromJSON (toJSON fingerprint) @?= Success fingerprint
          )
          [(Null, "148bdfa9-7596-5319-a197-ead64880df40"), (object [], "417e0a20-e3f9-59fc-8d1f-f51ab83a4318")],
      testCase "unproducible fingerprint encodings are refused" do
        let valid = payloadFingerprintText (payloadFingerprint (object []))
        mapM_
          ( \raw -> do
              assertBool "fingerprint parser refused" (isLeft (parsePayloadFingerprint raw))
              assertBool "fingerprint JSON refused" (case fromJSON (String raw) :: Result PayloadFingerprint of Error _ -> True; Success _ -> False)
          )
          ["", "not-a-uuid", Text.toUpper valid, "417e0a20-e3f9-49fc-8d1f-f51ab83a4318", "417e0a20-e3f9-59fc-0d1f-f51ab83a4318"],
      testCase "caller attribution retains the exact authenticated adapter claim" do
        mapM_
          (\raw -> callerAttributionText (callerAttribution raw) @?= raw)
          ["", "fixture", " caller ", "日本", "client/custom:v2"]
    ]
