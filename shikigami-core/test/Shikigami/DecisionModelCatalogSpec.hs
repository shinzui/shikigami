module Shikigami.DecisionModelCatalogSpec (tests) where

import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Model qualified as Model
import Baikai.Options (emptyOptions)
import Baikai.Options qualified as Options
import Control.Lens ((&), (.~))
import Data.Aeson (Value (Null, Object), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as AliasText
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Settei.Env (envSnapshot, environmentSource)
import Settei.Key (parseKey)
import Settei.Optparse (DiagnosticMode (..), cliOverride)
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.App.Config (AppConfig (..), Role (RunBehaviorRole), environmentBindings)
import Shikigami.App.Config.Load (ConfigOptions (..), ConfigRun (..), appConfigRun)
import Shikigami.Attestation.PolicyValue qualified as PV
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile, resolvedProfileFor)
import Shikigami.Behavior.Provider.Call (providerCallFor)
import Shikigami.Behavior.Provider.Coordinate qualified as Coordinate
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Decision.Contract
import Shikigami.Decision.ModelAlias qualified as Alias
import Shikigami.Decision.ModelCatalog
import Shikigami.Flow (FlowDef (..), flowRegistry)
import Shikigami.Program.Decision
import Shikigami.Trigger.Schedule (parseCron)
import Shikumi.Program (Program (Embed))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

registered :: RegisteredProgram Text Text
registered = mustRight (registerProgram "example" "1" "sha256:code" "input/1" "result/1" "validator/1" "derive/1" Null (Embed pure) jsonResultCodec Right Right)

registry :: ProgramRegistry
registry = mustRight (programRegistry [SomeProgram registered])

binding :: Text -> Text -> ModelBinding
binding alias exact = mustRight (modelBinding (fixtureModelAlias alias) "1" "binding" "1" ((stubModel & #modelId .~ (exact))) emptyOptions Nothing)

catalog :: ModelCatalog
catalog = mustRight (modelCatalog [binding "triage" "stub-triage", binding "investigate" "stub-investigate"])

slot :: DecisionSlot
slot = DecisionSlot triageDecisionSlot [descriptor (programRef registered)] [fixtureModelAlias "triage", fixtureModelAlias "investigate"]

tests :: TestTree
tests =
  testGroup
    "decision model admission"
    [ testCase "operator aliases and declaration intersect without a provider" do
        declaration <- allowedDeclaration
        let triage = mustRight (resolveModel catalog declaration Nothing (fixtureModelAlias "triage"))
            investigate = mustRight (resolveModel catalog declaration Nothing (fixtureModelAlias "investigate"))
        assertBool "exact models differ" (triage.modelId /= investigate.modelId)
        assertBool "unknown aliases denied" (isLeft (resolveModel catalog declaration Nothing (fixtureModelAlias "payload-model")))
        assertBool "agent permission required" (isLeft (resolveModel catalog ((declaration & #decisionModels .~ ([]))) Nothing (fixtureModelAlias "triage")))
        assertBool "duplicate operator aliases refused" (isLeft (modelCatalog [binding "triage" "stub-triage", binding "triage" "stub-investigate"])),
      testCase "model commitments retain the complete former binding preimage" do
        let admitted = binding "triage" "stub-triage"
            metadata = modelDescriptor admitted
            model = stubModel & #modelId .~ "stub-triage"
            old =
              versionedDigest
                "shikigami.decision-model/1"
                (object ["alias" .= ("triage" :: Text), "version" .= ("1" :: Text), "tuple" .= providerCallFor model emptyOptions, "model" .= model, "options" .= emptyOptions, "bindingId" .= ("binding" :: Text), "bindingVersion" .= ("1" :: Text)])
        modelDescriptorDigestText metadata.digest @?= old
        eitherDecode (encode metadata) @?= Right metadata
        mapM_ (\(version, key, revision) -> assertBool "missing registration refused before binding" (isLeft (modelBinding (fixtureModelAlias "triage") version key revision model emptyOptions Nothing))) [("", "binding", "1"), ("1", "", "1"), ("1", "binding", "")],
      testCase "whole-slot policy narrows to the pinned profile" do
        declaration <- allowedDeclaration
        let snapshot = mustRight (resolvePolicy registry [slot] catalog declaration (Just (profile "stub-triage")))
        map (\model -> Coordinate.providerCoordinateText model.modelId) snapshot.models @?= ["stub-triage"]
        snapshot.slots @?= [((slot & #models .~ ([fixtureModelAlias "triage"])) :: DecisionSlot)]
        assertBool "forbidden selected tuple" (isLeft (resolveModel catalog declaration (Just (profile "stub-triage")) (fixtureModelAlias "investigate"))),
      testCase "slot contracts and aliases validate before a runtime exists" do
        declaration <- allowedDeclaration
        slotErrors registry declaration [slot] @?= []
        assertBool "duplicate slot labels" (not (null (slotErrors registry declaration [slot, slot])))
        assertBool "unknown contract" (not (null (slotErrors (mustRight (programRegistry [])) declaration [slot])))
        assertBool "undeclared alias" (not (null (slotErrors registry ((declaration & #decisionModels .~ ([]))) [slot])))
        assertBool "existing flows have empty inventories" (all (\flow -> flow.name == declarationCoordinate "shikumi-decision-example" || null flow.decisionSlots) flowRegistry),
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
        assertBool "descriptor drift refused" (isLeft (pinnedBinding catalog ((wanted & #bindingVersion .~ (mustRight (parseModelRegistration "2")))))),
      testCase "Settei loads two finite aliases and rejects malformed selections" do
        let run = configRun [("behavior.decisionModels", specList ["stub-triage", "stub-investigate"])] NoDiagnostic
        run.exitCode @?= 0
        case run.resolved of
          Just config -> map (\model -> Coordinate.providerCoordinateText model.modelId) (catalogDescriptors (mustRight config.decisionModelCatalog)) @?= ["stub-triage", "stub-investigate"]
          Nothing -> assertFailure (Text.unpack run.standardError)
        (configRun [("behavior.decisionModels", specList ["invented-model"])] CheckConfig).exitCode @?= 4,
      testCase "HTTP endpoints and retention are immutable binding settings with legacy defaults" do
        let legacy = configuredHttpBinding []
            disabled = configuredHttpBinding ["cache_retention" .= ("none" :: Text)]
            short = configuredHttpBinding ["cache_retention" .= ("short" :: Text)]
            long = configuredHttpBinding ["cache_retention" .= ("long" :: Text)]
            gateway = configuredHttpBinding ["base_url" .= ("http://127.0.0.1:8791/v1" :: Text)]
            unchanged = configuredHttpBinding ["base_url" .= Model.baseUrl (bindingModel legacy)]
        Options.cacheRetention (bindingOptions legacy) @?= Nothing
        Options.cacheRetention (bindingOptions disabled) @?= Just CacheRetentionNone
        Options.cacheRetention (bindingOptions short) @?= Just CacheRetentionShort
        Options.cacheRetention (bindingOptions long) @?= Just CacheRetentionLong
        modelDescriptor unchanged @?= modelDescriptor legacy
        Model.baseUrl (bindingModel gateway) @?= "http://127.0.0.1:8791/v1"
        Coordinate.providerCoordinateText (modelDescriptor gateway).endpointClass @?= "http"
        for_ [disabled, short, long, gateway] \changed -> do
          assertBool "changed authority joins the digest" ((modelDescriptor changed).digest /= (modelDescriptor legacy).digest)
          assertBool "old version cannot rebind" (isLeft (retainModelBindings (mustRight (modelCatalog [changed])) [legacy]))
        let retained = mustRight (retainModelBindings (mustRight (modelCatalog [])) [legacy])
        assertBool "legacy binding remains available" (not (isLeft (pinnedBinding retained (modelDescriptor legacy)))),
      testCase "invalid nested HTTP/cache settings refuse offline and redact rejected values" do
        for_ ["", "file:///tmp/model", "https:///v1", "https://user:PLANTED_ENDPOINT_SECRET@example.test", "https://example.test/?key=PLANTED_ENDPOINT_SECRET", "https://example.test/#PLANTED_ENDPOINT_SECRET", "http://example.test/ private"] \endpoint -> do
          let run = httpConfigRun ["base_url" .= (endpoint :: Text)] ExplainJson
          run.exitCode @?= 4
          assertBool "endpoint secret redacted" (not ("PLANTED_ENDPOINT_SECRET" `Text.isInfixOf` (run.standardOutput <> run.standardError)))
        (httpConfigRun ["cache_retention" .= ("forever" :: Text)] CheckConfig).exitCode @?= 4
        -- The selected Chat binding cannot honor long retention; validation
        -- must fail before constructing a provider, even for a custom endpoint.
        (httpConfigRun ["provider" .= ("openai" :: Text), "model" .= ("gpt-4o" :: Text), "cache_retention" .= ("long" :: Text)] CheckConfig).exitCode @?= 4
        let stub = TE.decodeUtf8 . LBS.toStrict . encode $ [object ["alias" .= ("triage" :: Text), "version" .= ("1" :: Text), "bindingId" .= ("stub" :: Text), "bindingVersion" .= ("1" :: Text), "provider" .= ("stub" :: Text), "model" .= ("stub-triage" :: Text), "thinking" .= ("default" :: Text), "base_url" .= ("https://example.test" :: Text)]]
        (configRun [("behavior.decisionModels", stub)] CheckConfig).exitCode @?= 4,
      testCase "malformed nested credentials are redacted in diagnostic output" do
        let marker = "PLANTED_DECISION_CREDENTIAL"
            invalid = "[{\"alias\":\"triage\",\"credential\":\"" <> marker <> "\"}]"
            run = configRun [("behavior.decisionModels", invalid)] ExplainJson
        run.exitCode @?= 4
        assertBool "no secret in diagnostics" (not (marker `Text.isInfixOf` (run.standardOutput <> run.standardError)))
    ]

httpConfigRun :: [Pair] -> DiagnosticMode -> ConfigRun
httpConfigRun fields =
  configRun
    [ ("credentials.providers.anthropic.api_key", "public-fixture-key"),
      ("credentials.providers.openai.api_key", "public-fixture-key"),
      ("behavior.decisionModels", TE.decodeUtf8 . LBS.toStrict . encode $ [Object (KeyMap.fromList (defaults <> fields))])
    ]
  where
    defaults = ["alias" .= ("triage" :: Text), "version" .= ("1" :: Text), "bindingId" .= ("http" :: Text), "bindingVersion" .= ("1" :: Text), "provider" .= ("anthropic" :: Text), "model" .= ("claude-sonnet-4-6" :: Text), "thinking" .= ("default" :: Text)]

configuredHttpBinding :: [Pair] -> ModelBinding
configuredHttpBinding fields = case (httpConfigRun fields NoDiagnostic).resolved of
  Just config ->
    let resolved = mustRight config.decisionModelCatalog
     in mustRight (pinnedBinding resolved (head (catalogDescriptors resolved)))
  Nothing -> error (Text.unpack (httpConfigRun fields NoDiagnostic).standardError)

allowedDeclaration :: IO AgentDecl
allowedDeclaration = do
  declaration <- mustRight <$> loadAgent "../agents/heartbeat.dhall"
  pure ((declaration & #decisionModels .~ (map fixtureModelAlias ["triage", "investigate"])))

profile :: Text -> ResolvedProfile
profile exact = resolvedProfileFor content
  where
    content =
      Profile.SanctionedExecutionProfile
        { profileId = Profile.ProfileId "test",
          version = Profile.ProfileVersion "1",
          issuer = Profile.Issuer "test",
          lifecycle = Profile.Active,
          validFrom = UTCTime (fromGregorian 2026 1 1) 0,
          validUntil = Nothing,
          allowedCalls = Profile.AllowedCall (Coordinate.providerCoordinate "stub") (Coordinate.providerCoordinate "stub") (Coordinate.providerCoordinate "in-process") (Coordinate.providerCoordinate exact) Profile.ThinkingHigh :| [],
          prohibitions = (Profile.defaultProhibitions & #defaultedThinkingAllowed .~ (PV.Permitted)),
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

fixtureModelAlias :: AliasText.Text -> Alias.ModelAlias
fixtureModelAlias = either (error . show) id . Alias.parseModelAlias
