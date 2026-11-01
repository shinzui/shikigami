{-# LANGUAGE DataKinds #-}

module Shikigami.ExecutionPositionSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Claim
import Shikigami.Execution.Identity (AttemptId, OperationId, operationIdText, parseOperationId)
import Shikigami.Execution.Identity qualified as Entity
import Shikigami.Execution.Payload (parsePayloadByteCount, parsePayloadDigest, parsePayloadId)
import Shikigami.Execution.Policy.Types (RecoveryClass (RepeatableObservation), ToolInvoiceCost (NoInvoiceCost))
import Shikigami.Execution.Progress
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ToolPosition
import Shikigami.Execution.Transcript
import Shikigami.Fixture.ExecutionIdentity (fixtureAttemptId, fixtureOperationId)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.StateRevision
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "execution revision and operation positions"
    [ testCase "logical operation locators retain exact bytes and reject empty admission" do
        mapM_
          ( \raw -> do
              value <- either (assertFailure . show) pure (Entity.parseOperationId raw)
              Entity.operationIdText value @?= raw
              Aeson.encode value @?= Aeson.encode raw
              Aeson.eitherDecode (Aeson.encode value) @?= Right value
          )
          ["operation:a", " 名前 ", Text.replicate 400 "x"]
        assertBool "empty operation key admitted" (isLeft (Entity.parseOperationId ""))
        assertBool "empty operation JSON admitted" (isLeft (Aeson.eitherDecode @Entity.OperationId "\"\"")),
      testCase "accounting entities allocate distinct checked UUIDv7 domains" do
        assertEntityDomain Entity.parseExecutionRootId Entity.executionRootIdText Entity.newExecutionRootId "shikigami_execution_root"
        assertEntityDomain Entity.parseAttemptId Entity.attemptIdText Entity.newAttemptId "shikigami_execution_attempt"
        assertEntityDomain Entity.parseAllocationId Entity.allocationIdText Entity.newAllocationId "shikigami_execution_allocation"
        actual <- Entity.newAttemptId
        assertBool "attempt accepted as root" (isLeft (Entity.parseExecutionRootId (Entity.attemptIdText actual)))
        assertBool "attempt accepted as allocation" (isLeft (Entity.parseAllocationId (Entity.attemptIdText actual))),
      testCase "attempt claim owners and generations preserve complete retained bytes" do
        let owner = either (error . show) id (parseClaimOwner "fixture")
            generation = revision 3
            reference = Attempt.JobReference V1 execution (fixtureOperationId "operation") (fixtureAttemptId "attempt")
            request = Resources.AttemptRequest reference.attemptId reference.operationId Map.empty Resources.AdmittedUnknownUsage
            now = UTCTime (fromGregorian 2026 10 30) 0
            claim = Attempt.AttemptClaim reference owner generation
            attempt = Attempt.ExecutionAttempt V1 execution reference.operationId request "fingerprint" Nothing payload Attempt.Claimed (Just owner) generation (Just now) Nothing Nothing Nothing
            claimWire = Aeson.object ["reference" .= reference, "owner" .= Aeson.String "fixture", "generation" .= (3 :: Integer)]
            attemptWire = Aeson.object ["format" .= (1 :: Int), "executionId" .= execution, "operationId" .= reference.operationId, "request" .= request, "fingerprint" .= Aeson.String "fingerprint", "call" .= Aeson.Null, "wake" .= payload, "phase" .= Attempt.Claimed, "owner" .= Aeson.String "fixture", "generation" .= (3 :: Integer), "expiresAt" .= now, "outcome" .= Aeson.Null, "lateReceipt" .= Aeson.Null, "uncertainty" .= Aeson.Null]
        assertWire claim claimWire
        assertWire attempt attemptWire
        mapM_ (\value -> fmap claimOwnerText (Aeson.eitherDecode (Aeson.encode value)) @?= Right value) [" ", "日本", Text.replicate 256 "x"]
        case attemptWire of
          Aeson.Object fields -> do
            mapM_
              ( \bad -> do
                  assertBool "invalid owner refused" (isLeft (parseClaimOwner bad))
                  assertBool "invalid retained owner refused" (case Aeson.fromJSON (Aeson.Object (KeyMap.insert "owner" (Aeson.toJSON bad) fields)) :: Aeson.Result Attempt.ExecutionAttempt of Aeson.Error _ -> True; _ -> False)
              )
              ["", Text.replicate 257 "x"]
            mapM_ (\bad -> assertBool "invalid active generation refused" (case Aeson.fromJSON (Aeson.Object (KeyMap.insert "generation" (Aeson.toJSON (bad :: Integer)) fields)) :: Aeson.Result Attempt.ExecutionAttempt of Aeson.Error _ -> True; _ -> False)) [-1, 0]
          _ -> assertFailure "attempt control was not an object",
      testCase "tool positions retain full input, continuation and specification bytes" do
        let position = checkedToolPosition 3
            invocation = ToolInvocation "call" "observe" (Aeson.object [])
            binding = ToolBinding "observe" "1" "schema" RepeatableObservation NoInvoiceCost
            input = ToolOperationInput payload position invocation binding
            next = NeedTool payload position
            specification = OperationSpec (operationIdFor execution (revision 7)) ToolOperation RepeatableObservation "observe" "policy" "scope" (Just position)
            inputWire = Aeson.object ["response" .= payload, "position" .= (3 :: Int), "invocation" .= invocation, "binding" .= binding]
            nextWire = Aeson.object ["tag" .= Aeson.String "NeedTool", "contents" .= [Aeson.toJSON payload, Aeson.toJSON (3 :: Int)]]
            specWire = Aeson.object ["operationId" .= specification.operationId, "kind" .= ToolOperation, "recovery" .= RepeatableObservation, "name" .= Aeson.String "observe", "policyDigest" .= Aeson.String "policy", "scopeDigest" .= Aeson.String "scope", "responsePosition" .= (3 :: Int)]
        assertWire input inputWire
        assertWire next nextWire
        assertWire specification specWire
        Aeson.eitherDecode (Aeson.encode (255 :: Int)) @?= Right (checkedToolPosition 255)
        nextToolPosition firstToolPosition @?= Just (checkedToolPosition 1)
        nextToolPosition (checkedToolPosition 255) @?= Nothing
        mapM_
          ( \bad -> do
              assertBool "invalid tool position refused" (case parseToolPosition bad of Left _ -> True; Right _ -> False)
              case inputWire of
                Aeson.Object fields -> assertBool "invalid retained input refused" (case Aeson.fromJSON (Aeson.Object (KeyMap.insert "position" (Aeson.toJSON bad) fields)) :: Aeson.Result ToolOperationInput of Aeson.Error _ -> True; Aeson.Success _ -> False)
                _ -> assertFailure "input wire control was not an object"
          )
          [-1, 256],
      testCase "state revisions and positions keep exact numeric bytes and bounds" do
        let state = ExecutionState V1 execution (revision 5) Active (revision 7) NeedModel payload Nothing Nothing (progress 2) (progress 3) Nothing Nothing (progress 4)
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
            operation = Operation V1 execution (revision 7) specification "fingerprint" payload Nothing Nothing NotMarkedUncertain Nothing
            encoded = Aeson.toJSON operation
        Aeson.fromJSON encoded @?= Aeson.Success operation
        case encoded of
          Aeson.Object fields -> do
            fmap Aeson.encode (KeyMap.lookup "position" fields) @?= Just "7"
            fmap Aeson.encode (KeyMap.lookup "uncertain" fields) @?= Just "false"
            let uncertainWire = Aeson.Object (KeyMap.insert "uncertain" (Aeson.Bool True) fields)
            case Aeson.fromJSON uncertainWire :: Aeson.Result Operation of
              Aeson.Error failure -> assertFailure failure
              Aeson.Success uncertain -> do
                uncertain.uncertain @?= MarkedUncertain
                Aeson.encode uncertain @?= Aeson.encode uncertainWire
            mapM_ (\number -> refusedOperation (Aeson.Object (KeyMap.insert "position" (Aeson.toJSON (number :: Integer)) fields))) [-1, 8]
          _ -> assertFailure "operation did not encode as an object"
    ]
  where
    execution = ExecutionId "execution:position-codec"
    payload = fixturePayloadRef "payload:fixture" ("sha256:" <> Text.replicate 64 "a") 1
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

checkedToolPosition :: Integer -> ToolPosition
checkedToolPosition value = either (error . show) id (parseToolPosition value)

assertWire :: (Eq a, Show a, Aeson.ToJSON a, Aeson.FromJSON a) => a -> Aeson.Value -> Assertion
assertWire value expected = do
  Aeson.eitherDecode (Aeson.encode value) @?= Right value
  Aeson.encode value @?= Aeson.encode expected

fixturePayloadRef :: Text -> Text -> Integer -> PayloadRef
fixturePayloadRef locator digest size =
  PayloadRef
    (either (error . show) id (parsePayloadId locator))
    (either (error . show) id (parsePayloadDigest digest))
    (either (error . show) id (parsePayloadByteCount size))

assertEntityDomain :: forall a. (Eq a, Show a, Aeson.FromJSON a, Aeson.ToJSON a) => (Text -> Either Text a) -> (a -> Text) -> IO a -> Text -> IO ()
assertEntityDomain parse render allocate prefix = do
  first <- allocate
  second <- allocate
  assertBool "allocation reused an identity" (first /= second)
  parse (render first) @?= Right first
  Aeson.encode first @?= Aeson.encode (render first)
  Aeson.eitherDecode (Aeson.encode first) @?= Right first
  mapM_
    (\raw -> assertBool "invalid entity domain accepted" (isLeft (parse raw)))
    [prefix <> "_5q2yqxm4kkaka84gadcrsgwfyk", "not-an-entity", " " <> render first, Text.toUpper (render first)]
