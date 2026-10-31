module Shikigami.AgentRun.ApiSpec (tests) where

import Data.Aeson (encode, object)
import Data.Aeson qualified as Aeson
import Data.Either (isLeft)
import Data.OpenApi (validateToJSON)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Shikigami.AgentRun.Api
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "agent-run wire contract"
    [ testCase "HTTP request keys preserve valid strings and reject invalid input" do
        mapM_
          ( \value -> do
              Aeson.eitherDecode (encode value) @?= Right (key value)
              encode (key value) @?= encode value
              Aeson.eitherDecode (encode (AgentRunRequest (key value) (object []))) @?= Right (AgentRunRequest (key value) (object []))
          )
          [" ", "a:http:b", "日本", Text.replicate 200 "x"]
        mapM_
          ( \value -> do
              assertBool "factory refuses invalid key" (isLeft (parseRequestKey value))
              assertBool "wire refuses invalid key" (case Aeson.eitherDecode (encode value) :: Either String RequestKey of Left _ -> True; _ -> False)
          )
          ["", "line\nkey", Text.replicate 201 "x"],
      testCase "history rows have a stable wire shape" $
        encode (RunRequestView "run" "key" (UTCTime (fromGregorian 2026 10 25) 0) "caller" "accepted")
          @?= "{\"acceptedAt\":\"2026-10-25T00:00:00Z\",\"disposition\":\"accepted\",\"idempotencyKey\":\"key\",\"requestedBy\":\"caller\",\"runId\":\"run\"}",
      statusTests,
      testCase "request bytes are stable" $
        encode request @?= "{\"idempotencyKey\":\"key\",\"payload\":{}}",
      testCase "acceptance bytes are stable" $
        encode accepted @?= "{\"acceptedAt\":\"2026-10-25T00:00:00Z\",\"agentName\":\"heartbeat\",\"idempotencyKey\":\"key\",\"runId\":\"heartbeat:http:key\",\"status\":\"accepted\"}",
      testCase "wire bodies satisfy the published schemas" do
        validateToJSON request @?= []
        validateToJSON accepted @?= []
    ]
  where
    request = AgentRunRequest (key "key") (object [])
    accepted = AgentRunAccepted "heartbeat:http:key" "heartbeat" "key" "accepted" (UTCTime (fromGregorian 2026 10 25) 0)

statusTests :: TestTree
statusTests = testGroup "lifecycle bytes and schema" [testCase label (check (Text.pack label) literal) | (label, literal) <- vectors]
  where
    check status literal = do
      let failure = if status == "failed" then Just (RunFailureView "behavior_failed" "failed") else Nothing
          view = AgentRunStatus "run" "heartbeat" status Nothing Nothing Nothing Nothing Nothing Nothing failure
      encode view @?= literal
      validateToJSON view @?= []
    vectors =
      [ ("accepted", "{\"acceptedAt\":null,\"agentName\":\"heartbeat\",\"completedAt\":null,\"failure\":null,\"runId\":\"run\",\"sessionId\":null,\"startedAt\":null,\"status\":\"accepted\",\"summary\":null,\"trigger\":null}"),
        ("running", "{\"acceptedAt\":null,\"agentName\":\"heartbeat\",\"completedAt\":null,\"failure\":null,\"runId\":\"run\",\"sessionId\":null,\"startedAt\":null,\"status\":\"running\",\"summary\":null,\"trigger\":null}"),
        ("succeeded", "{\"acceptedAt\":null,\"agentName\":\"heartbeat\",\"completedAt\":null,\"failure\":null,\"runId\":\"run\",\"sessionId\":null,\"startedAt\":null,\"status\":\"succeeded\",\"summary\":null,\"trigger\":null}"),
        ("failed", "{\"acceptedAt\":null,\"agentName\":\"heartbeat\",\"completedAt\":null,\"failure\":{\"kind\":\"behavior_failed\",\"reason\":\"failed\"},\"runId\":\"run\",\"sessionId\":null,\"startedAt\":null,\"status\":\"failed\",\"summary\":null,\"trigger\":null}"),
        ("cancelled", "{\"acceptedAt\":null,\"agentName\":\"heartbeat\",\"completedAt\":null,\"failure\":null,\"runId\":\"run\",\"sessionId\":null,\"startedAt\":null,\"status\":\"cancelled\",\"summary\":null,\"trigger\":null}")
      ]

key :: Text.Text -> RequestKey
key = either (error . show) id . parseRequestKey
