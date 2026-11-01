module Shikigami.DirectoryValueSpec (tests) where

import Data.Aeson (encode)
import Data.Text (Text)
import Shikigami.Directory.Store
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "reported directory claims"
    [ testCase "invalid and empty reported principals remain exact refusal evidence" do
        mapM_
          ( \raw -> do
              let claim = reportedPrincipalClaim raw
              reportedPrincipalClaimText claim @?= raw
              encode claim @?= encode raw
          )
          (["", "not-a-principal", "agent_heartbeat", " agent ", "日本"] :: [Text])
    ]
