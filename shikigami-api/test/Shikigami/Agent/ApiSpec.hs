module Shikigami.Agent.ApiSpec (tests) where

import Data.Aeson (encode)
import Data.OpenApi (validateToJSON)
import Relay.Pagination (Connection (..), PageInfo (..))
import Shikigami.Agent.Api
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "agent wire contract"
    [ testCase "agent view bytes are stable" $
        encode fixture @?= "{\"behavior\":\"skill\",\"delegates\":[],\"description\":\"A\",\"enabled\":true,\"lifecycle\":\"unverified\",\"name\":\"a\",\"principalId\":null,\"runnable\":true,\"sinks\":[],\"trigger\":\"event\"}",
      testCase "empty connection bytes are stable" $
        encode (Connection [] (PageInfo False False Nothing Nothing) :: Connection AgentView)
          @?= "{\"edges\":[],\"pageInfo\":{\"hasNextPage\":false,\"hasPreviousPage\":false,\"startCursor\":null,\"endCursor\":null}}",
      testCase "the view validates against its schema" $ validateToJSON fixture @?= []
    ]

fixture :: AgentView
fixture = AgentView "a" "A" True "event" "skill" [] [] Nothing "unverified" True
