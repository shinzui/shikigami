{-# LANGUAGE DataKinds #-}

-- | The pack value: what it composes, the setting it owns and the manifests
-- it ships. The golden label inventory is checked where the flow's branches
-- are run, in "FlowPack.PracticeReview.OrchestrationSpec".
module FlowPack.PracticeReview.PackSpec (tests) where

import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import FlowPack.PracticeReview (practiceReviewPack)
import FlowPack.PracticeReview.Capability (emptyAttentionRecipientMap, renderAttentionRecipientMap)
import FlowPack.PracticeReview.Settings (attentionRecipientsFrom, attentionRecipientsKey, attentionRecipientsSetting)
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.App.Config (AppConfig (..), Role (AdminRole), environmentBindingsWith)
import Shikigami.App.Config.Load (ConfigOptions (..), ConfigRun (..), DiagnosticMode (NoDiagnostic), appConfigRunWith, resolutionExitCode)
import Shikigami.Flow.Builtin (builtinPack)
import Shikigami.Flow.Pack
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Pack.Setting (packSettingsFromList)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests _ =
  testGroup
    "the practice-review pack"
    [ compositionTests,
      settingTests,
      manifestTests
    ]

flowNames :: [Text]
flowNames = ["architecture-practice-router", "opentelemetry-practice-review"]

compositionTests :: TestTree
compositionTests =
  testGroup
    "composition"
    [ testCase "the pack composes beside the builtin pack and owns both flows" do
        registry <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack, practiceReviewPack])
        mapM_
          (\name -> fmap (flowPackNameText . (.pack)) (lookupFlow registry (declarationCoordinate name)) @?= Just "practice-review")
          flowNames
        flowPackNameText <$> registeredPacks registry @?= ["builtin", "practice-review"],
      testCase "the builtin pack alone has neither flow" do
        registry <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack])
        mapM_
          (\name -> assertBool (Text.unpack name <> " left the core") (null (lookupFlow registry (declarationCoordinate name))))
          flowNames,
      testCase "composing the pack twice is refused, naming the pack and its setting" do
        case composeFlowRegistry [builtinPack, practiceReviewPack, practiceReviewPack] of
          Left errors -> do
            assertBool "the duplicate pack is named" (DuplicatePackName practiceReviewPack.name `elem` NonEmpty.toList errors)
            assertBool "the duplicate setting is named" (DuplicateSettingKey attentionRecipientsKey practiceReviewPack.name practiceReviewPack.name `elem` NonEmpty.toList errors)
          Right _ -> assertFailure "a pack composed twice must be refused"
    ]

-- | The setting keeps the key, the variable and the refusals it had while the
-- kernel declared it.
settingTests :: TestTree
settingTests =
  testGroup
    "practice_review.attention_recipients"
    [ testCase "the pack declares the key and its environment variable" do
        [(setting.key, setting.environment) | setting <- practiceReviewPack.settings]
          @?= [("practice_review.attention_recipients", "SHIKIGAMI_PRACTICE_REVIEW_ATTENTION_RECIPIENTS")],
      testCase "a composed executable resolves it from the environment, canonicalizing owner sets" do
        config <- resolved [("SHIKIGAMI_PRACTICE_REVIEW_ATTENTION_RECIPIENTS", "triage+target-owner=recipient_one")]
        renderAttentionRecipientMap (attentionRecipientsFrom config.packSettings) @?= "target-owner+triage=recipient_one",
      testCase "unset, it is the empty map, which fails closed" do
        config <- resolved []
        attentionRecipientsFrom config.packSettings @?= emptyAttentionRecipientMap,
      testCase "noncanonical destinations and duplicate owner sets refuse to start" do
        mapM_
          (\bad -> (run [("SHIKIGAMI_PRACTICE_REVIEW_ATTENTION_RECIPIENTS", bad)]).exitCode @?= resolutionExitCode)
          [ "target-owner=recipient:wrong",
            "target-owner=recipient_one,target-owner=recipient_two",
            "target-owner+triage=recipient_one,triage+target-owner=recipient_two"
          ],
      testCase "a value no executable validated is treated as unmapped" do
        attentionRecipientsFrom (packSettingsFromList [(attentionRecipientsKey, "not a map")]) @?= emptyAttentionRecipientMap
    ]
  where
    settings = practiceReviewPack.settings
    run environment =
      appConfigRunWith
        settings
        AdminRole
        ConfigOptions {configPaths = [], namedSources = [], overrides = [], diagnosticMode = NoDiagnostic}
        (Right [])
        (environmentSource (either (error . Text.unpack) id (environmentBindingsWith settings)) (envSnapshot environment))
    resolved environment =
      let attempt = run environment
       in maybe (assertFailure (Text.unpack attempt.standardError)) pure attempt.resolved

manifestTests :: TestTree
manifestTests =
  testGroup
    "shipped manifests"
    [ testCase "each manifest loads and names a flow of this pack" do
        registry <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack, practiceReviewPack])
        mapM_
          ( \file ->
              loadAgent ("agents/" <> file) >>= \case
                Left problem -> assertFailure (file <> ": " <> show problem)
                Right declaration -> flowDeclarationErrors registry declaration @?= []
          )
          ["architecture-practice-router.dhall", "opentelemetry-practice-reviewer.dhall"],
      testCase "the stock composition refuses each manifest, naming the flows it has" do
        registry <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack])
        mapM_
          ( \file ->
              loadAgent ("agents/" <> file) >>= \case
                Left problem -> assertFailure (file <> ": " <> show problem)
                Right declaration@AgentDecl {} ->
                  assertBool file (any ("unknown flow" `Text.isPrefixOf`) (flowDeclarationErrors registry declaration))
          )
          ["architecture-practice-router.dhall", "opentelemetry-practice-reviewer.dhall"]
    ]
