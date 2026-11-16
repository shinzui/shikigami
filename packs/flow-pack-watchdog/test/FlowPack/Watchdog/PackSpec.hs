{-# LANGUAGE DataKinds #-}

-- | The pack value: what it composes, the setting it owns, the verbs it
-- mounts, the manifest it ships and the durable labels its flow journals.
module FlowPack.Watchdog.PackSpec (tests) where

import Control.Monad (forM_)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import FlowPack.Watchdog (watchdogPack)
import FlowPack.Watchdog.Command (overdueExitCode)
import FlowPack.Watchdog.Inspection (OverdueVerdict (..))
import FlowPack.Watchdog.Setting (watchdogKey, watchdogSettingsFrom)
import FlowPack.Watchdog.Settings (WatchdogSettings (..))
import FlowPack.Watchdog.SweepSpec (journaledLabels)
import FlowPack.Watchdog.Types (episodeIdText, newEpisodeId)
import Options.Applicative qualified as Options
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.App.Config (AppConfig (..), Role (AdminRole), environmentBindingsWith)
import Shikigami.App.Config.Load (ConfigOptions (..), ConfigRun (..), DiagnosticMode (NoDiagnostic), appConfigRunWith, resolutionExitCode)
import Shikigami.Decision.Contract (DecisionSlot (..))
import Shikigami.Flow (FlowDef (..))
import Shikigami.Flow.Builtin (builtinPack)
import Shikigami.Flow.Pack
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "the watchdog pack"
    [ compositionTests,
      settingTests,
      verbTests,
      manifestTests,
      labelTests fixture
    ]

compositionTests :: TestTree
compositionTests =
  testGroup
    "composition"
    [ testCase "the pack composes beside the builtin pack and owns the flow, its program, its verb, its hook and its gauge" do
        registry <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack, watchdogPack])
        fmap (flowPackNameText . (.pack)) (lookupFlow registry (declarationCoordinate "watchdog-sweep")) @?= Just "watchdog"
        [verb.name | verb <- watchdogPack.adminVerbs] @?= ["watchdog"]
        [(flowPackNameText pack, gauge.name) | (pack, gauge) <- registeredGauges registry] @?= [("watchdog", "sweep.age")]
        assertBool "the pack has a schedule hook and no stream hook" (isJust watchdogPack.triggers.schedule && isNothing watchdogPack.triggers.stream)
        forM_ [slot | entry <- registeredFlows registry, entry.pack == watchdogPack.name, slot <- entry.flow.definition.decisionSlots] \declared ->
          assertBool "the declared slot resolves its program" (not (null declared.programs)),
      testCase "the builtin pack alone has no sweep" do
        registry <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack])
        assertBool "watchdog-sweep left the core" (null (lookupFlow registry (declarationCoordinate "watchdog-sweep")))
        assertBool "the stock worker samples no gauge" (null (registeredGauges registry)),
      testCase "composing the pack twice is refused" do
        case composeFlowRegistry [builtinPack, watchdogPack, watchdogPack] of
          Left errors -> assertBool "the duplicate pack is named" (DuplicatePackName watchdogPack.name `elem` NonEmpty.toList errors)
          Right _ -> assertFailure "a pack composed twice must be refused"
    ]

-- | The setting keeps the key, the variable and the refusals it had while the
-- kernel declared it.
settingTests :: TestTree
settingTests =
  testGroup
    "watchdog"
    [ testCase "the pack declares the key and its environment variable" do
        [(setting.key, setting.environment) | setting <- watchdogPack.settings] @?= [(watchdogKey, "SHIKIGAMI_WATCHDOG")],
      testCase "omission disables observation" do
        config <- resolved watchdogPack.settings []
        assertBool "unset" (isNothing (watchdogSettingsFrom config.packSettings)),
      testCase "an environment object resolves" do
        config <- resolved watchdogPack.settings [("SHIKIGAMI_WATCHDOG", document)]
        principal <- either (assertFailure . Text.unpack) pure (mkAgentPrincipal "agent_watchdog")
        fmap (.principal) (watchdogSettingsFrom config.packSettings) @?= Just (VerifiedIdentity principal),
      testCase "bad limits refuse the key" do
        forM_
          [Text.replace "60" "0" document, Text.replace "60" "-1" document, Text.replace "10" "0" document, Text.replace "\"scope\":\"all\"" "\"scope\":{\"objectives\":[]}" document]
          \value -> (run watchdogPack.settings [("SHIKIGAMI_WATCHDOG", value)]).exitCode @?= resolutionExitCode
    ]
  where
    options = ConfigOptions {configPaths = [], namedSources = [], overrides = [], diagnosticMode = NoDiagnostic}
    run settings environment =
      appConfigRunWith settings AdminRole options (Right []) (environmentSource (either (error . Text.unpack) id (environmentBindingsWith settings)) (envSnapshot environment))
    resolved settings environment =
      let attempt = run settings environment
       in maybe (assertFailure (Text.unpack attempt.standardError)) pure attempt.resolved
    document :: Text
    document = "{\"principal\":\"agent_watchdog\",\"scope\":\"all\",\"stuckWindowSeconds\":60,\"parkedWindowSeconds\":60,\"coordinatorWindowSeconds\":60,\"subjectsPerSweep\":10}"

-- | The @watchdog@ verb keeps the commands and options it had as a kernel
-- verb.
verbTests :: TestTree
verbTests =
  testGroup
    "watchdog verbs"
    [ testCase "bounded inspection and pagination parse" do
        episode <- Text.unpack . episodeIdText <$> newEpisodeId
        forM_
          [ ["inspect", "--agents", "agents", "--grace", "0", "--fail-when-overdue", "--json"],
            ["episodes", "--open", "--limit", "100", "--json"],
            ["findings", episode, "--limit", "1", "--json"]
          ]
          \args -> case parse args of Options.Success _ -> pure (); _ -> assertFailure (unwords args),
      testCase "invalid page bounds and a negative grace are refused before IO" do
        forM_
          [["episodes", "--limit", "0"], ["episodes", "--limit", "101"], ["inspect", "--grace", "-1"], ["findings", "invalid"]]
          \args -> case parse args of Options.Failure _ -> pure (); _ -> assertFailure (unwords args),
      testCase "the overdue check exits two for a missing or overdue completion" do
        overdueExitCode True SweepFresh @?= ExitSuccess
        overdueExitCode True NoSweepYet @?= ExitFailure 2
        overdueExitCode True ScheduleUnknown @?= ExitFailure 2
        overdueExitCode False NoSweepYet @?= ExitSuccess
    ]
  where
    parse = case watchdogPack.adminVerbs of
      [verb] -> Options.execParserPure Options.defaultPrefs verb.parser
      _ -> error "the pack mounts exactly one verb"

-- | The shipped manifest declares the flow this pack provides, on a schedule.
manifestTests :: TestTree
manifestTests =
  testGroup
    "manifest"
    [ testCase "agents/watchdog.dhall runs watchdog-sweep" do
        declaration <- loadAgent "../packs/flow-pack-watchdog/agents/watchdog.dhall" >>= either (assertFailure . show) pure
        case declaration.behavior of
          Flow {name} -> name @?= declarationCoordinate "watchdog-sweep"
          _ -> assertFailure "the watchdog manifest must run a flow"
    ]

-- | The golden label inventory. keiro-diff cannot see a label declared outside
-- the kernel specification, so this file is the pack's replay contract.
labelTests :: DatabaseFixture -> TestTree
labelTests fixture =
  testGroup
    "durable labels"
    [ testCase "a sweep with delivery and a drift assessment journals exactly the golden labels, each the pack's own" do
        labels <- journaledLabels fixture
        golden <- Text.lines <$> TextIO.readFile "../packs/flow-pack-watchdog/test/golden/labels.txt"
        assertEqual "the pack's durable labels changed; review test/golden/labels.txt" golden labels
        forM_ labels \label -> assertBool (Text.unpack label <> " does not carry the pack's name") ("watchdog" `Text.isInfixOf` label)
    ]
