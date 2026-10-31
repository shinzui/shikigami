{-# LANGUAGE DataKinds #-}

module Shikigami.DecisionContractSpec (tests) where

import Baikai.Evidence qualified as Evidence
import Control.Exception (SomeException, try)
import Control.Lens ((&), (.~))
import Control.Monad (forM_)
import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as AliasText
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Dhall qualified
import GHC.Generics (Generic)
import Shikigami.Decision.Contract
import Shikigami.Decision.ModelAlias qualified as Alias
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
model = ModelDescriptor (fixtureModelAlias "triage") "1" "sha256:model" "stub" "stub" "in-process" "stub-a" Nothing "stub-binding" "1"

prepared :: PreparedDecision
prepared = PreparedDecision "prepare-1" (runCorrelationId "run-1") "workflow-1" 0 "triage" (descriptor (programRef original)) (object ["request" .= ("hello" :: Text)]) model Nothing

tests :: TestTree
tests =
  testGroup
    "typed decision contracts"
    [ testCase "model alias codecs keep exact names and reject empty lookup keys" do
        forM_ ["triage", "日本", " ", "alias\0suffix", Text.replicate 1000 "x"] \text -> do
          let alias = fixtureModelAlias text
          modelAliasText alias @?= text
          toJSON alias @?= toJSON text
          eitherDecode (encode alias) @?= Right alias
        assertBool "empty factory refused" (isLeft (parseModelAlias ""))
        assertBool "empty JSON refused" (isLeft (eitherDecode @ModelAlias "\"\"")),
      testCase "Dhall alias admission uses the checked lookup domain" do
        Dhall.input Dhall.auto "\"triage\"" >>= (@?= fixtureModelAlias "triage")
        refused <- try @SomeException (Dhall.input Dhall.auto "\"\"" :: IO ModelAlias)
        assertBool "empty Dhall lookup name refused" (isLeft refused),
      testCase "program identity scopes and computed parameter contracts retain checked wire values" do
        let raw = " \nλ:opaque-version "
            identity = mustRight (parseProgramIdentity raw :: Either Text (ProgramIdentity "implementation-digest"))
            digest = programParameterDigest (object ["state" .= ("fixture" :: Text)])
        programIdentityText identity @?= raw
        encode identity @?= encode raw
        eitherDecode (encode identity) @?= Right identity
        assertBool "empty identity refused" (isLeft (parseProgramIdentity "" :: Either Text (ProgramIdentity "program-id")))
        parseProgramParameterDigest (programParameterDigestText digest) @?= Right digest
        encode digest @?= encode (programParameterDigestText digest)
        eitherDecode (encode digest) @?= Right digest
        forM_ ["", "sha256:implementation", Text.toUpper (programParameterDigestText digest), "sha256:" <> Text.replicate 64 "g"] \invalid ->
          assertBool "invalid parameter digest refused" (isLeft (parseProgramParameterDigest invalid))
        encode ParametersV1 @?= "1"
        eitherDecode (encode ParametersV1) @?= Right ParametersV1
        case toJSON (descriptor (programRef original)) of
          Object fields -> do
            forM_ ["programId", "version", "implementationDigest", "inputSchemaVersion", "resultSchemaVersion", "validatorVersion", "derivationVersion"] \key ->
              assertBool "complete descriptor refuses empty identity" (isLeft (eitherDecode @ProgramDescriptor (encode (Object (KeyMap.insert key (String "") fields)))))
            forM_ [Number 0, Number 2, Number (-1), Number 1.5] \invalid ->
              assertBool "complete descriptor refuses unsupported parameter format" (isLeft (eitherDecode @ProgramDescriptor (encode (Object (KeyMap.insert "parameterFormat" invalid fields)))))
            assertBool "complete descriptor refuses malformed parameter digest" (isLeft (eitherDecode @ProgramDescriptor (encode (Object (KeyMap.insert "parameterDigest" (String "sha256:parameters") fields)))))
          _ -> assertFailure "expected descriptor object",
      testCase "allocated call identity and positive ordinal keep exact primitive codecs" do
        token <- newAttemptToken firstDecisionCallOrdinal
        let identifier = attemptId token
            rendered = decisionCallIdText identifier
        assertBool "allocated kind" ("shikigami_decision_call_" `Text.isPrefixOf` rendered)
        parseDecisionCallId rendered @?= Right identifier
        encode identifier @?= encode rendered
        eitherDecode (encode identifier) @?= Right identifier
        mapM_
          (\invalid -> assertBool "invalid call identity refused" (isLeft (parseDecisionCallId invalid)))
          [ "",
            Text.toUpper rendered,
            " " <> rendered,
            "shikigami_decision_call_5q2yqxm4kkaka84gadcrsgwfyk",
            Text.replace "shikigami_decision_call_" "shikigami_execution_attempt_" rendered
          ]
        mapM_
          (\invalid -> assertBool "invalid ordinal refused" (isLeft (parseDecisionCallOrdinal invalid)))
          [-1, 0, toInteger (maxBound :: Int64) + 1]
        assertBool "zero JSON refused" (isLeft (eitherDecode @DecisionCallOrdinal "0"))
        assertBool "fractional JSON refused" (isLeft (eitherDecode @DecisionCallOrdinal "1.5"))
        encode firstDecisionCallOrdinal @?= "1"
        eitherDecode (encode firstDecisionCallOrdinal) @?= Right firstDecisionCallOrdinal,
      testCase "typed lookup checks immutable descriptor and type witnesses" do
        let registry = mustRight (programRegistry [SomeProgram original])
        assertBool "matching registration" (not (isLeft (lookupProgram registry (programRef original))))
        assertBool "unavailable immutable version" (isLeft (lookupProgram registry (programRef (registration "2" emptyParams))))
        let other :: RegisteredProgram Int Bool
            other = mustRight (registerProgram "example" "1" "sha256:implementation" "input/1" "result/1" "validator/1" "derive/1" Null (Embed (\_ -> pure True)) jsonResultCodec Right Right)
        assertBool "wrong witnesses never cast" (isLeft (lookupProgram registry (programRef other))),
      testCase "effective instruction and demonstrations change identity without changing shape" do
        let changed = (emptyParams & #instructionOverride .~ (Just "Changed instruction"))
        programShape (program emptyParams) @?= programShape (program changed)
        assertBool "parameters are bound" (descriptor (programRef original) /= descriptor (programRef (registration "1" changed)))
        let withDemos = (emptyParams & #demos .~ ([Demo (object ["request" .= ("example" :: Text)]) (object ["answer" .= ("return" :: Text), "confidence" .= (0.9 :: Double)])]))
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
        let policy = DecisionPolicySnapshot [DecisionSlot "triage" [descriptor (programRef original)] [fixtureModelAlias "triage"]] [model] Nothing
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
        decisionCallOrdinalNumber (attemptOrdinal first) @?= 1
        decisionCallOrdinalNumber (attemptOrdinal second) @?= 2
        calls <- inspect
        Map.size calls @?= 2
        Map.lookup (attemptId first) calls @?= Just (MemoryCall (DecisionCallContext prepared model) Nothing)
        hooks.finishCall (withAttemptOrdinal (attemptOrdinal second) first) CallFailed Nothing >>= (assertBool "wrong ordinal refused" . isLeft)
        hooks.finishCall first CallFailed Nothing >>= (@?= Right ())
        hooks.finishCall first CallFailed Nothing >>= (@?= Right ())
        conflict <- hooks.finishCall first CallUnknown Nothing
        assertBool "conflicting terminal refused" (isLeft conflict)
        missing <- hooks.finishCall second CallSucceeded Nothing
        assertBool "confidence cannot replace provider evidence" (isLeft missing)
        orphan <- newAttemptToken (mustRight (parseDecisionCallOrdinal 3))
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

fixtureModelAlias :: AliasText.Text -> Alias.ModelAlias
fixtureModelAlias = either (error . show) id . Alias.parseModelAlias
