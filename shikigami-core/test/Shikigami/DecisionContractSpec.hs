{-# LANGUAGE DataKinds #-}

module Shikigami.DecisionContractSpec (tests) where

import Baikai.Evidence qualified as Evidence
import Control.Exception (SomeException, try)
import Control.Lens ((&), (.~))
import Control.Monad (forM_)
import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
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
import Keiro.Workflow.Types (WorkflowId (..))
import Shikigami.Behavior.Provider.Coordinate qualified as Coordinate
import Shikigami.Decision.Contract
import Shikigami.Decision.Contract qualified as Model
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
model = ModelDescriptor (fixtureModelAlias "triage") (fixtureModelRegistration "1") (modelDescriptorDigest (toJSON ("model" :: Text))) (Coordinate.providerCoordinate "stub") (Coordinate.providerCoordinate "stub") (Coordinate.providerCoordinate "in-process") (Coordinate.providerCoordinate "stub-a") Nothing (fixtureModelRegistration "stub-binding") (fixtureModelRegistration "1")

prepared :: PreparedDecision
prepared = PreparedDecision (decisionPreparationId (String "prepare-1")) (runCorrelationId "run-1") (WorkflowId "workflow-1") initialDecisionGeneration triageDecisionSlot (descriptor (programRef original)) (object ["request" .= ("hello" :: Text)]) model Nothing

tests :: TestTree
tests =
  testGroup
    "typed decision contracts"
    [ testCase "provider coordinates preserve the exact foreign vocabulary" do
        forM_ ["", "日本", " ", "custom+api", Text.replicate 1000 "x"] \raw -> do
          let value = Coordinate.providerCoordinate raw :: Coordinate.ProviderCoordinate "provider-api"
          Coordinate.providerCoordinateText value @?= raw
          toJSON value @?= toJSON raw
          eitherDecode (encode value) @?= Right value
        assertBool "non-string provider metadata refuses" (isLeft (eitherDecode @(Coordinate.ProviderCoordinate "provider-name") "1")),
      testCase "model alias codecs keep exact names and reject empty lookup keys" do
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
      testCase "model registration and computed commitments have checked codecs" do
        let raw = " opaque:model-version λ "
            coordinate = mustRight (parseModelRegistration raw :: Either Text (ModelRegistration "model-version"))
            digest = modelDescriptorDigest (object ["fixture" .= raw])
        modelRegistrationText coordinate @?= raw
        eitherDecode (encode coordinate) @?= Right coordinate
        toJSON coordinate @?= toJSON raw
        parseModelRegistration @"model-version" "" @?= Left "model registration coordinate must not be empty"
        parseModelDescriptorDigest (modelDescriptorDigestText digest) @?= Right digest
        eitherDecode (encode digest) @?= Right digest
        toJSON digest @?= toJSON (modelDescriptorDigestText digest)
        eitherDecode (encode model) @?= Right model
        case toJSON model of
          Object fields -> forM_ ["version", "bindingId", "bindingVersion", "digest"] \field ->
            assertBool "invalid retained registration refused" (case Aeson.fromJSON @ModelDescriptor (Object (KeyMap.insert field (toJSON ("" :: Text)) fields)) of Aeson.Error _ -> True; _ -> False)
          _ -> assertFailure "model control was not an object"
        forM_ ["", "sha256:model", "sha256:" <> Text.replicate 64 "A", "sha256:" <> Text.replicate 63 "a"] \bad ->
          assertBool "invalid commitment refused" (isLeft (parseModelDescriptorDigest bad)),
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
      testCase "preparation coordinates preserve primitive bytes and the original commitment domain" do
        let commitment = decisionPreparationId (object ["fixture" .= ("preparation" :: Text)])
        decisionPreparationIdText commitment @?= "sha256:0aa7eb22843827bba4cd2e44f660dc4655fabc6cf45d4906b3b477795f2dedf3"
        eitherDecode (encode commitment) @?= Right commitment
        toJSON commitment @?= toJSON (decisionPreparationIdText commitment)
        forM_ ["A", "triage", "other_slot-2", Text.replicate 1000 "x"] \raw -> do
          let label = mustRight (parseDecisionSlotLabel raw)
          decisionSlotLabelText label @?= raw
          encode label @?= encode raw
          eitherDecode (encode label) @?= Right label
        forM_ [0, 1, toInteger (maxBound :: Int) + 1] \number -> do
          let generation = mustRight (parseDecisionGeneration number)
          toInteger (decisionGenerationNumber generation) @?= number
          encode generation @?= encode number
          eitherDecode (encode generation) @?= Right generation
        assertBool "negative generation refused" (isLeft (parseDecisionGeneration (-1)))
        forM_ ["", "-first", "_first", "has space", "日本", "label\0tail"] \raw ->
          assertBool "existing slot grammar is checked at admission" (isLeft (parseDecisionSlotLabel raw))
        forM_ ["", "prepare-1", "sha256:" <> Text.replicate 64 "A", "sha256:" <> Text.replicate 63 "a"] \raw ->
          assertBool "unproducible preparation commitment refused" (isLeft (parseDecisionPreparationId raw)),
      testCase "complete preparation codecs retain legacy fields and reject a substituted coordinate" do
        let legacy = object ["identity" .= decisionPreparationIdText prepared.identity, "runId" .= prepared.runId, "workflowId" .= ("workflow-1" :: Text), "generation" .= (0 :: Integer), "label" .= ("triage" :: Text), "program" .= prepared.program, "input" .= prepared.input, "model" .= prepared.model, "policy" .= prepared.policy]
            outcome = DecisionOutcome prepared.identity prepared.program (Right Null) []
        encode prepared @?= encode legacy
        eitherDecode (encode legacy) @?= Right prepared
        case legacy of
          Object fields -> do
            eitherDecode (encode (Object (KeyMap.delete "policy" fields))) @?= Right prepared
            forM_ [("identity", String "not-a-commitment"), ("label", String "invalid label"), ("generation", toJSON (-1 :: Integer)), ("generation", toJSON (0.5 :: Double))] \(key, invalid) ->
              assertBool "complete preparation refuses the changed coordinate" (isLeft (eitherDecode @PreparedDecision (encode (Object (KeyMap.insert key invalid fields)))))
          _ -> assertFailure "legacy control was not an object"
        eitherDecode (encode outcome) @?= Right outcome
        case toJSON outcome of
          Object fields -> assertBool "outcome shares the checked preparation commitment" (isLeft (eitherDecode @DecisionOutcome (encode (Object (KeyMap.insert "preparationId" (String "not-a-commitment") fields)))))
          _ -> assertFailure "outcome control was not an object"
        -- The native runtime owns compatibility coordinates. The JSON adapter
        -- keeps all historical strings rather than imposing new journal syntax.
        forM_ ["", "legacy:workflow#1", "opaque λ"] \raw -> do
          let value = prepared & #workflowId .~ WorkflowId raw
          eitherDecode (encode value) @?= Right value,
      testCase "policy, preparation, outcome and failure round-trip" do
        let policy = DecisionPolicySnapshot [DecisionSlot triageDecisionSlot [descriptor (programRef original)] [fixtureModelAlias "triage"]] [model] Nothing
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

fixtureModelRegistration :: AliasText.Text -> Model.ModelRegistration scope
fixtureModelRegistration = either (error . show) id . Model.parseModelRegistration
