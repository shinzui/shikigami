{-# LANGUAGE DataKinds #-}

module Shikigami.ExecutionPositionSpec (tests) where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Policy.Types (RecoveryClass (RepeatableObservation))
import Shikigami.Execution.Progress
import Shikigami.Execution.Transcript
import Shikigami.StateRevision
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "execution revision and operation positions"
    [ testCase "state revisions and positions keep exact numeric bytes and bounds" do
        let state = ExecutionState 1 execution (revision 5) Active (revision 7) NeedModel payload Nothing Nothing (progress 2) (progress 3) Nothing Nothing (progress 4)
            encoded = Aeson.toJSON state
        Aeson.fromJSON encoded @?= Aeson.Success state
        case encoded of
          Aeson.Object fields -> do
            fmap Aeson.encode (KeyMap.lookup "revision" fields) @?= Just "5"
            fmap Aeson.encode (KeyMap.lookup "cursor" fields) @?= Just "7"
            fmap Aeson.encode (KeyMap.lookup "repairs" fields) @?= Just "2"
            fmap Aeson.encode (KeyMap.lookup "modelTurns" fields) @?= Just "3"
            fmap Aeson.encode (KeyMap.lookup "pendingReceipts" fields) @?= Just "4"
            mapM_ (\(key, number) -> refusedState (Aeson.Object (KeyMap.insert key (Aeson.toJSON (number :: Integer)) fields))) [("revision", -1), ("cursor", -1), ("cursor", 10001), ("repairs", -1), ("repairs", 11), ("modelTurns", -1), ("modelTurns", 10001), ("pendingReceipts", -1), ("pendingReceipts", 1000001)]
          _ -> assertFailure "state did not encode as an object",
      testCase "technical operation derivation retains its primitive wire input" do
        let expected = "operation:" <> versionedDigest "shikigami.execution-operation/1" (Aeson.toJSON (execution, 7 :: Integer))
        Aeson.toJSON (operationIdFor execution (revision 7)) @?= Aeson.toJSON expected,
      testCase "operation codec retains numeric position and rejects another identity" do
        let specification = OperationSpec (operationIdFor execution (revision 7)) ModelTurn RepeatableObservation "model" "policy" "scope" Nothing
            operation = Operation 1 execution (revision 7) specification "fingerprint" payload Nothing Nothing False Nothing
            encoded = Aeson.toJSON operation
        Aeson.fromJSON encoded @?= Aeson.Success operation
        case encoded of
          Aeson.Object fields -> do
            fmap Aeson.encode (KeyMap.lookup "position" fields) @?= Just "7"
            mapM_ (\number -> refusedOperation (Aeson.Object (KeyMap.insert "position" (Aeson.toJSON (number :: Integer)) fields))) [-1, 8]
          _ -> assertFailure "operation did not encode as an object"
    ]
  where
    execution = ExecutionId "execution:position-codec"
    payload = PayloadRef "payload:fixture" "digest" 1
    refusedState value = case Aeson.fromJSON value :: Aeson.Result ExecutionState of
      Aeson.Error _ -> pure ()
      Aeson.Success _ -> assertFailure "invalid state admitted"
    refusedOperation value = case Aeson.fromJSON value :: Aeson.Result Operation of
      Aeson.Error _ -> pure ()
      Aeson.Success _ -> assertFailure "invalid operation admitted"

revision :: Integer -> StateRevision scope
revision number = either (error . show) id (parseRevision number)

progress :: (ProgressNumber a) => Integer -> a
progress number = either (error . show) id (parseProgress number)
