{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Shikigami.FormatVersionSpec (tests) where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Shikigami.Execution.Attempt (JobReference (..))
import Shikigami.Execution.Identity (newAttemptId)
import Shikigami.Execution.Policy.Types (defaultHarnessPolicy)
import Shikigami.Execution.Transcript (ExecutionId (..))
import Shikigami.Fixture.ExecutionIdentity (fixtureOperationId)
import Shikigami.FormatVersion (FormatVersion (V1))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "closed format versions"
    [ testCase "the closed selector preserves the exact numeric wire representation" do
        Aeson.encode (V1 :: FormatVersion "execution-state") @?= "1"
        Aeson.eitherDecode "1" @?= Right (V1 :: FormatVersion "execution-state")
        mapM_ refuse invalidVersions,
      testCase "complete execution job references reject unsupported versions" do
        attempt <- newAttemptId
        assertCompleteFormats (JobReference V1 (ExecutionId "execution") (fixtureOperationId "operation") attempt),
      testCase "complete harness policies reject unsupported versions" do
        assertCompleteFormats defaultHarnessPolicy
    ]
  where
    refuse value = case Aeson.fromJSON value :: Aeson.Result (FormatVersion "execution-state") of
      Aeson.Error _ -> pure ()
      Aeson.Success _ -> assertFailure "unsupported format admitted"

invalidVersions :: [Aeson.Value]
invalidVersions = [Aeson.Number (-1), Aeson.Number 0, Aeson.Number 2, Aeson.Number 1.5, Aeson.Number (10 ^ (100 :: Int)), Aeson.String "1", Aeson.Bool True, Aeson.Null]

assertCompleteFormats :: forall a. (Eq a, Show a, Aeson.ToJSON a, Aeson.FromJSON a) => a -> Assertion
assertCompleteFormats valid = do
  Aeson.eitherDecode (Aeson.encode valid) @?= Right valid
  case Aeson.toJSON valid of
    Aeson.Object fields -> do
      KeyMap.lookup "format" fields @?= Just (Aeson.Number 1)
      mapM_
        (\bad -> assertBool "unsupported complete value admitted" (case Aeson.fromJSON @a (Aeson.Object (KeyMap.insert "format" bad fields)) of Aeson.Error _ -> True; _ -> False))
        invalidVersions
    _ -> assertFailure "complete valid control was not an object"
