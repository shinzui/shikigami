module Shikigami.DecisionModelCatalogSpec (tests) where

import Baikai.Model qualified as Model
import Baikai.Options (emptyOptions)
import Data.Aeson (Value (Null, Object), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Settei.Env (envSnapshot, environmentSource)
import Settei.Key (parseKey)
import Settei.Optparse (DiagnosticMode (..), cliOverride)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.App.Config (AppConfig (..), Role (RunBehaviorRole), environmentBindings)
import Shikigami.App.Config.Load (ConfigOptions (..), ConfigRun (..), appConfigRun)
import Shikigami.Attestation.Envelope (profileDigest)
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile (..))
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Decision.Contract
import Shikigami.Decision.ModelCatalog
import Shikigami.Flow (FlowDef (..), flowRegistry)
import Shikigami.Program.Decision
import Shikumi.Program (Program (Embed))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

registered :: RegisteredProgram Text Text
registered = mustRight (registerProgram "example" "1" "sha256:code" "input/1" "result/1" "validator/1" "derive/1" Null (Embed pure) jsonResultCodec Right Right)

registry :: ProgramRegistry
registry = mustRight (programRegistry [SomeProgram registered])

binding :: Text -> Text -> ModelBinding
binding alias exact = mustRight (modelBinding (ModelAlias alias) "1" "binding" "1" (stubModel {Model.modelId = exact}) emptyOptions Nothing)

catalog :: ModelCatalog
catalog = mustRight (modelCatalog [binding "triage" "stub-triage", binding "investigate" "stub-investigate"])

slot :: DecisionSlot
slot = DecisionSlot "triage" [descriptor (programRef registered)] [ModelAlias "triage", ModelAlias "investigate"]

tests :: TestTree
tests =
  testGroup
    "decision model admission"
    [ testCase "operator aliases and declaration intersect without a provider" do
        declaration <- allowedDeclaration
        let triage = mustRight (resolveModel catalog declaration Nothing (ModelAlias "triage"))
            investigate = mustRight (resolveModel catalog declaration Nothing (ModelAlias "investigate"))
        assertBool "exact models differ" (triage.modelId /= investigate.modelId)
        assertBool "unknown aliases denied" (isLeft (resolveModel catalog declaration Nothing (ModelAlias "payload-model")))
        assertBool "agent permission required" (isLeft (resolveModel catalog (declaration {decisionModels = []}) Nothing (ModelAlias "triage")))
        assertBool "duplicate operator aliases refused" (isLeft (modelCatalog [binding "triage" "stub-triage", binding "triage" "stub-investigate"])),
      testCase "whole-slot policy narrows to the pinned profile" do
        declaration <- allowedDeclaration
        let snapshot = mustRight (resolvePolicy registry [slot] catalog declaration (Just (profile "stub-triage")))
        map (\model -> model.modelId) snapshot.models @?= ["stub-triage"]
        snapshot.slots @?= [(slot {models = [ModelAlias "triage"]} :: DecisionSlot)]
        assertBool "forbidden selected tuple" (isLeft (resolveModel catalog declaration (Just (profile "stub-triage")) (ModelAlias "investigate"))),
      testCase "slot contracts and aliases validate before a runtime exists" do
        declaration <- allowedDeclaration
        slotErrors registry declaration [slot] @?= []
        assertBool "duplicate slot labels" (not (null (slotErrors registry declaration [slot, slot])))
        assertBool "unknown contract" (not (null (slotErrors (mustRight (programRegistry [])) declaration [slot])))
        assertBool "undeclared alias" (not (null (slotErrors registry (declaration {decisionModels = []}) [slot])))
        assertBool "existing flows have empty inventories" (all (\flow -> flow.name == "shikumi-decision-example" || null flow.decisionSlots) flowRegistry),
      testCase "historical declaration JSON defaults to no permission and keeps its bytes" do
        declaration <- mustRight <$> loadAgent "../agents/heartbeat.dhall"
        case toJSON declaration of
          Object fields -> do
            assertBool "empty permission key omitted" (not (KeyMap.member "decisionModels" fields))
            eitherDecode (encode declaration) @?= Right declaration
          _ -> assertFailure "expected declaration object",
      testCase "changed option identity cannot replace a pinned binding" do
        let wanted = modelDescriptor (binding "triage" "stub-triage")
        assertBool "retained binding found" (not (isLeft (pinnedBinding catalog wanted)))
        assertBool "descriptor drift refused" (isLeft (pinnedBinding catalog (wanted {bindingVersion = "2"}))),
      testCase "Settei loads two finite aliases and rejects malformed selections" do
        let run = configRun [("behavior.decisionModels", specList ["stub-triage", "stub-investigate"])] NoDiagnostic
        run.exitCode @?= 0
        case run.resolved of
          Just config -> map (\model -> model.modelId) (catalogDescriptors (mustRight config.decisionModelCatalog)) @?= ["stub-triage", "stub-investigate"]
          Nothing -> assertFailure (Text.unpack run.standardError)
        (configRun [("behavior.decisionModels", specList ["invented-model"])] CheckConfig).exitCode @?= 4,
      testCase "malformed nested credentials are redacted in diagnostic output" do
        let marker = "PLANTED_DECISION_CREDENTIAL"
            invalid = "[{\"alias\":\"triage\",\"credential\":\"" <> marker <> "\"}]"
            run = configRun [("behavior.decisionModels", invalid)] ExplainJson
        run.exitCode @?= 4
        assertBool "no secret in diagnostics" (not (marker `Text.isInfixOf` (run.standardOutput <> run.standardError)))
    ]

allowedDeclaration :: IO AgentDecl
allowedDeclaration = do
  declaration <- mustRight <$> loadAgent "../agents/heartbeat.dhall"
  pure (declaration {decisionModels = ["triage", "investigate"]})

profile :: Text -> ResolvedProfile
profile exact = ResolvedProfile content (Profile.SanctionedExecutionProfileRef (Profile.ProfileId "test") (Profile.ProfileVersion "1") (profileDigest content))
  where
    content =
      Profile.SanctionedExecutionProfile
        { profileId = Profile.ProfileId "test",
          version = Profile.ProfileVersion "1",
          issuer = Profile.Issuer "test",
          lifecycle = Profile.Active,
          validFrom = UTCTime (fromGregorian 2026 1 1) 0,
          validUntil = Nothing,
          allowedCalls = Profile.AllowedCall "stub" "stub" "in-process" exact Profile.ThinkingHigh :| [],
          prohibitions = Profile.defaultProhibitions {Profile.defaultedThinkingAllowed = True},
          limits = Profile.unlimitedProfileLimits,
          minimumEvidenceStrength = Profile.EvidenceModelObserved,
          requiredCorrelationFields = [],
          signerRequirements = Profile.noSignerRequirements
        }

specList :: [Text] -> Text
specList models =
  TE.decodeUtf8 . LBS.toStrict . encode $
    [ object
        [ "alias" .= (if exact == "stub-investigate" then "investigate" else "triage" :: Text),
          "version" .= ("1" :: Text),
          "provider" .= ("stub" :: Text),
          "model" .= exact,
          "thinking" .= ("default" :: Text),
          "bindingId" .= ("stub" :: Text),
          "bindingVersion" .= ("1" :: Text)
        ]
    | exact <- models
    ]

configRun :: [(Text, Text)] -> DiagnosticMode -> ConfigRun
configRun values diagnosticMode =
  appConfigRun
    RunBehaviorRole
    ConfigOptions {configPaths = [], namedSources = [], overrides = [cliOverride (mustRight (parseKey key)) value | (key, value) <- values], diagnosticMode}
    (Right [])
    (environmentSource environmentBindings (envSnapshot []))

mustRight :: (Show e) => Either e a -> a
mustRight = either (error . show) id
