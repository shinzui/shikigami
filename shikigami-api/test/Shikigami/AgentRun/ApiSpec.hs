module Shikigami.AgentRun.ApiSpec (tests) where

import Data.Aeson (encode, object)
import Data.OpenApi (validateToJSON)
import Data.Time (UTCTime (..), fromGregorian)
import Shikigami.AgentRun.Api
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "agent-run wire contract"
    [ testCase "request bytes are stable" $
        encode request @?= "{\"idempotencyKey\":\"key\",\"payload\":{}}",
      testCase "acceptance bytes are stable" $
        encode accepted @?= "{\"acceptedAt\":\"2026-10-25T00:00:00Z\",\"agentName\":\"heartbeat\",\"idempotencyKey\":\"key\",\"runId\":\"heartbeat:http:key\",\"status\":\"accepted\"}",
      testCase "wire bodies satisfy the published schemas" do
        validateToJSON request @?= []
        validateToJSON accepted @?= []
    ]
  where
    request = AgentRunRequest "key" (object [])
    accepted = AgentRunAccepted "heartbeat:http:key" "heartbeat" "key" "accepted" (UTCTime (fromGregorian 2026 10 25) 0)
