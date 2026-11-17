-- | The pack API's own rules: a checked pack name, and a registry that
-- refuses every collision at composition instead of at the first run.
module Shikigami.FlowPackSpec (tests) where

import Data.Aeson (Value (Null))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Agent.DeclarationValue (declarationCoordinate, declarationCoordinateText)
import Shikigami.Flow (DecisionMode (..), FlowDef (..), LifecycleDiagram (..))
import Shikigami.Flow.Builtin (builtinFlowRegistry, builtinPack)
import Shikigami.Flow.Pack
import Shikigami.Program.Registry (noopSummaryTask)
import Shikigami.RuntimePolicy (DefaultModelRequirement (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "flow packs"
    [ testCase "a pack name is lowercase words joined by hyphens, at most 64 bytes" do
        fmap flowPackNameText (parseFlowPackName "examples") @?= Right "examples"
        fmap flowPackNameText (parseFlowPackName "repository-ledger-2") @?= Right "repository-ledger-2"
        parseFlowPackName "" @?= Left EmptyFlowPackName
        mapM_
          (\raw -> parseFlowPackName raw @?= Left (MalformedFlowPackName raw))
          ["Examples", "two words", "-leading", "trailing-", "double--hyphen", "snake_case", Text.replicate 65 "a"],
      testCase "the builtin pack composes, and its flows are found with their pack" do
        registeredPacks builtinFlowRegistry @?= [packName "builtin"]
        case lookupFlow builtinFlowRegistry (declarationCoordinate "adaptive-delivery") of
          Just entry -> entry.pack @?= packName "builtin"
          Nothing -> assertFailure "adaptive-delivery is a builtin flow"
        assertBool "an unknown flow misses" (null (lookupFlow builtinFlowRegistry (declarationCoordinate "no-such-flow")))
        assertBool "a builtin task is found" (not (null (lookupTask builtinFlowRegistry "noop-summary")))
        assertBool "an unknown task misses" (null (lookupTask builtinFlowRegistry "no-such-task")),
      testCase "a second pack's flows join the registry after the builtin ones" do
        registry <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack, probePack "probe" ["probe-flow"]])
        registeredPacks registry @?= [packName "builtin", packName "probe"]
        fmap (.pack) (lookupFlow registry (declarationCoordinate "probe-flow")) @?= Just (packName "probe")
        last (map declarationCoordinateText (registeredFlowNames registry)) @?= "probe-flow",
      testCase "every collision is reported with both owners" do
        refusals [probePack "probe" [], probePack "probe" []] @?= [DuplicatePackName (packName "probe")]
        refusals [probePack "first" ["shared"], probePack "second" ["shared"]]
          @?= [DuplicateFlowName (declarationCoordinate "shared") (packName "first") (packName "second")]
        refusals [builtinPack, (probePack "probe" []) {tasks = [noopSummaryTask]}]
          @?= [DuplicateTaskName "noop-summary" (packName "builtin") (packName "probe")]
        refusals [withSetting (probePack "first" []), withSetting (probePack "second" [])]
          @?= [DuplicateSettingKey "probe.parity" (packName "first") (packName "second")]
        length (refusals [builtinPack, (probePack "probe" ["adaptive-delivery"]) {decisionPrograms = builtinPack.decisionPrograms, retainedCodecs = builtinPack.retainedCodecs}]) @?= 3,
      testCase "flow names keep composition order" do
        registry <- either (assertFailure . show) pure (composeFlowRegistry [probePack "probe" ["one", "two"]])
        registeredFlowNames registry @?= [declarationCoordinate "one", declarationCoordinate "two"]
    ]
  where
    refusals = either NonEmpty.toList (const []) . composeFlowRegistry

packName :: Text -> FlowPackName
packName = either (error . show) id . parseFlowPackName

-- | The same pack, declaring one configuration setting.
withSetting :: FlowPack -> FlowPack
withSetting FlowPack {name, flows, decisionPrograms, retainedCodecs, tasks} =
  FlowPack
    { name,
      flows,
      decisionPrograms,
      retainedCodecs,
      tasks,
      settings =
        [ PackSetting
            { key = "probe.parity",
              environment = "SHIKIGAMI_PROBE_PARITY",
              description = "Which parity the probe pack prefers",
              expectation = "the word even or odd",
              shape = TextSetting,
              whenAbsent = Nothing,
              validate = const (Right ())
            }
        ],
      triggers = noTriggerHooks,
      adminVerbs = [],
      gauges = [],
      authorities = [],
      outputs = [],
      approvalChannels = [],
      trackerProviders = []
    }

probePack :: Text -> [Text] -> FlowPack
probePack name flowNames =
  FlowPack
    { name = packName name,
      flows = [kernelCapabilityFlow (definition flowName) (const (pure Null)) | flowName <- flowNames],
      decisionPrograms = [],
      retainedCodecs = [],
      tasks = [],
      settings = [],
      triggers = noTriggerHooks,
      adminVerbs = [],
      gauges = [],
      authorities = [],
      outputs = [],
      approvalChannels = [],
      trackerProviders = []
    }
  where
    definition flowName =
      FlowDef
        { name = declarationCoordinate flowName,
          lifecycle = LifecycleDiagram "flowchart LR\n Start --> End" [],
          decisionSlots = [],
          requiresDefaultModel = DefaultModelOptional,
          decisionMode = StrictDecisions
        }
