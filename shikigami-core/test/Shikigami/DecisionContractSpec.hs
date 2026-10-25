module Shikigami.DecisionContractSpec (tests) where

import Baikai.Evidence qualified as Evidence
import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecode, encode, object, (.=))
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import GHC.Generics (Generic)
import Shikigami.Decision.Contract
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Program.Decision
import Shikumi.Adapter (ToPrompt)
import Shikumi.Program (Demo (..), Params (..), Program (..), emptyParams, programShape)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

data Request = Request {request :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, FromModel, ToSchema, Validatable, ToPrompt)

data Answer = Answer {answer :: !Text, confidence :: !Double}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, FromModel, ToSchema, Validatable, ToPrompt)

program :: Params -> Program Request Answer
program = Predict (mkSignature "Return a bounded decision")

registration :: Text -> Params -> RegisteredProgram Request Answer
registration version params = mustRight (registerProgram "example" version "sha256:implementation" "input/1" "result/1" "validator/1" "derive/1" Null (program params) jsonResultCodec Right Right)

original :: RegisteredProgram Request Answer
original = registration "1" emptyParams

model :: ModelDescriptor
model = ModelDescriptor (ModelAlias "triage") "1" "sha256:model" "stub" "stub" "in-process" "stub-a" Nothing "stub-binding" "1"

prepared :: PreparedDecision
prepared = PreparedDecision "prepare-1" (runCorrelationId "run-1") "workflow-1" 0 "triage" (descriptor (programRef original)) (object ["request" .= ("hello" :: Text)]) model Nothing

tests :: TestTree
tests =
  testGroup
    "typed decision contracts"
    [ testCase "typed lookup checks immutable descriptor and type witnesses" do
        let registry = mustRight (programRegistry [SomeProgram original])
        assertBool "matching registration" (not (isLeft (lookupProgram registry (programRef original))))
        assertBool "unavailable immutable version" (isLeft (lookupProgram registry (programRef (registration "2" emptyParams))))
        let other :: RegisteredProgram Int Bool
            other = mustRight (registerProgram "example" "1" "sha256:implementation" "input/1" "result/1" "validator/1" "derive/1" Null (Embed (\_ -> pure True)) jsonResultCodec Right Right)
        assertBool "wrong witnesses never cast" (isLeft (lookupProgram registry (programRef other))),
      testCase "effective instruction and demonstrations change identity without changing shape" do
        let changed = emptyParams {instructionOverride = Just "Changed instruction"}
        programShape (program emptyParams) @?= programShape (program changed)
        assertBool "parameters are bound" (descriptor (programRef original) /= descriptor (programRef (registration "1" changed)))
        let withDemos = emptyParams {demos = [Demo (object ["request" .= ("example" :: Text)]) (object ["answer" .= ("return" :: Text), "confidence" .= (0.9 :: Double)])]}
        assertBool "demonstrations are bound" (descriptor (programRef original) /= descriptor (programRef (registration "1" withDemos)))
        assertBool "immutable registration collision" (isLeft (programRegistry [SomeProgram original, SomeProgram (registration "1" changed)])),
      testCase "pure derivation defaults change immutable identity" do
        let other = mustRight (registerProgram "example" "1" "sha256:implementation" "input/1" "result/1" "validator/1" "derive/1" (object ["threshold" .= (0.9 :: Double)]) (program emptyParams) jsonResultCodec Right Right)
        assertBool "local state is bound" (descriptor (programRef original) /= descriptor (programRef other)),
      testCase "retained result codec survives an empty executable registry and keeps confidence" do
        let codecs = mustRight (resultCodecRegistry [retainedCodec original])
            codec = mustRight (lookupResultCodec @Answer codecs (descriptor (programRef original)))
            output = Answer "investigate" 0.73
        assertBool "executable absent" (isLeft (lookupProgram (mustRight (programRegistry [])) (programRef original)))
        decodeResult codec (encodeResult codec output) @?= Right output,
      testCase "policy, preparation, outcome and failure round-trip" do
        let policy = DecisionPolicySnapshot [DecisionSlot "triage" [descriptor (programRef original)] [ModelAlias "triage"]] [model] Nothing
            outcome = DecisionOutcome prepared.identity prepared.program (Right (object ["answer" .= ("return" :: Text), "confidence" .= (0.9 :: Double)])) []
            failure = decisionFailure InvalidInput (Text.replicate 800 "x")
        eitherDecode (encode policy) @?= Right policy
        eitherDecode (encode prepared) @?= Right prepared
        eitherDecode (encode outcome) @?= Right outcome
        eitherDecode (encode failure) @?= Right failure
        Text.length (renderDecisionFailure failure) @?= 512,
      testCase "unknown envelope versions fail visibly" do
        assertBool "policy" (isLeft (eitherDecode @DecisionPolicySnapshot (encode (object ["format" .= (2 :: Int)]))))
        assertBool "outcome" (isLeft (eitherDecode @DecisionOutcome (encode (object ["format" .= (2 :: Int)])))),
      testCase "call hooks allocate fresh expectations and enforce terminal convergence" do
        (hooks, inspect) <- newMemoryCallHooks
        first <- mustRight <$> hooks.beginCall (DecisionCallContext prepared model)
        second <- mustRight <$> hooks.beginCall (DecisionCallContext prepared model)
        assertBool "retry gets a different identity" (attemptId first /= attemptId second)
        attemptOrdinal first @?= 1
        attemptOrdinal second @?= 2
        calls <- inspect
        Map.size calls @?= 2
        Map.lookup (attemptId first) calls @?= Just (MemoryCall (DecisionCallContext prepared model) Nothing)
        hooks.finishCall first CallFailed Nothing >>= (@?= Right ())
        hooks.finishCall first CallFailed Nothing >>= (@?= Right ())
        conflict <- hooks.finishCall first CallUnknown Nothing
        assertBool "conflicting terminal refused" (isLeft conflict)
        missing <- hooks.finishCall second CallSucceeded Nothing
        assertBool "confidence cannot replace provider evidence" (isLeft missing)
        orphan <- newAttemptToken 3
        refused <- hooks.finishCall orphan CallFailed Nothing
        assertBool "unknown attempt refused" (isLeft refused)
        let epoch = UTCTime (fromGregorian 2026 1 1) 0
            evidence =
              Evidence.baseEvidence
                (Evidence.evidenceRequest "run-1")
                "provider-call-1"
                (Evidence.EndpointIdentity "stub" "stub" Evidence.TransportAgentRun Nothing "0.7.2.0" (Just "fixture/1"))
                "stub-a"
                Evidence.noThinkingRequested
                epoch
                epoch
                Evidence.CallSucceeded
                "sha256:request"
                "sha256:config"
        hooks.finishCall second CallSucceeded (Just evidence) >>= (@?= Right ())
        hooks.finishCall second CallSucceeded (Just evidence) >>= (@?= Right ()),
      testCase "domain failure does not expose validator internals" do
        let reject = mustRight (registerProgram "rejected" "1" "sha256:code" "input/1" "result/1" "validator/1" "derive/1" Null (program emptyParams) jsonResultCodec (const (Left "secret prompt marker")) Right)
        case validateInput reject (Request "input") of
          Right _ -> assertFailure "expected refusal"
          Left failure -> do
            failureCode failure @?= InvalidInput
            assertBool "private details omitted" (not ("secret" `Text.isInfixOf` renderDecisionFailure failure))
    ]

mustRight :: (Show e) => Either e a -> a
mustRight = either (error . show) id
