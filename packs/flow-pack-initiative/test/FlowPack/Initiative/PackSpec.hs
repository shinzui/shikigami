{-# LANGUAGE DataKinds #-}

-- | The pack value: what it composes, the setting it owns, the manifest it
-- ships and the durable labels its flow journals.
module FlowPack.Initiative.PackSpec (tests) where

import Control.Lens ((&), (.~))
import Control.Monad (forM_)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import FlowPack.Initiative (initiativePack)
import FlowPack.Initiative.Fixture.Proposing
import FlowPack.Initiative.Setting (initiativeSettingsFrom, initiativesKey)
import FlowPack.Initiative.Settings (InitiativeSettings (..), ObserverAllowance (..))
import Options.Applicative qualified as Options
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Principal (principalText)
import Shikigami.App.Config (AppConfig (..), Role (AdminRole), environmentBindingsWith)
import Shikigami.App.Config.Load (ConfigOptions (..), ConfigRun (..), DiagnosticMode (NoDiagnostic), appConfigRunWith, resolutionExitCode)
import Shikigami.Decision.Contract (DecisionSlot (..))
import Shikigami.Flow (FlowDef (..))
import Shikigami.Flow.Builtin (builtinPack)
import Shikigami.Flow.Pack
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "the initiative pack"
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
    [ testCase "the pack composes beside the builtin pack and owns the flow, its program and its verb" do
        registry <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack, initiativePack])
        fmap (flowPackNameText . (.pack)) (lookupFlow registry (declarationCoordinate "propose-work")) @?= Just "initiative"
        flowPackNameText <$> registeredPacks registry @?= ["builtin", "initiative"]
        [verb.name | verb <- initiativePack.adminVerbs] @?= ["proposals"]
        forM_ [slot | entry <- registeredFlows registry, entry.pack == initiativePack.name, slot <- entry.flow.definition.decisionSlots] \declared ->
          assertBool "the declared slot resolves its program" (not (null declared.programs)),
      testCase "the builtin pack alone has no proposing flow" do
        registry <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack])
        assertBool "propose-work left the core" (null (lookupFlow registry (declarationCoordinate "propose-work"))),
      testCase "composing the pack twice is refused" do
        case composeFlowRegistry [builtinPack, initiativePack, initiativePack] of
          Left errors -> assertBool "the duplicate pack is named" (DuplicatePackName initiativePack.name `elem` NonEmpty.toList errors)
          Right _ -> assertFailure "a pack composed twice must be refused"
    ]

-- | The setting keeps the key, the variable and the refusals it had while the
-- kernel declared it.
settingTests :: TestTree
settingTests =
  testGroup
    "initiatives"
    [ testCase "the pack declares the key and its environment variable" do
        [(setting.key, setting.environment) | setting <- initiativePack.settings] @?= [(initiativesKey, "SHIKIGAMI_INITIATIVES")],
      testCase "omission disables observation" do
        config <- resolved []
        assertBool "unset" (null (initiativeSettingsFrom config.packSettings)),
      testCase "a valid allowance resolves" do
        config <- resolved [("SHIKIGAMI_INITIATIVES", initiativeDocument allowanceFields)]
        fmap (map (principalText . (.principal)) . (.observers)) (initiativeSettingsFrom config.packSettings) @?= Just ["agent_proposer"],
      testCase "unknown keys, duplicates, zero durations and envelopes denying a model call refuse to start" do
        forM_
          [ initiativeDocument ("\"surprise\":1," <> allowanceFields),
            "{\"observers\":[{" <> allowanceFields <> "},{" <> allowanceFields <> "}]}",
            "{\"observers\":[],\"surprise\":1}",
            initiativeDocument (Text.replace "\"window\":3600" "\"window\":0" allowanceFields),
            initiativeDocument (Text.replace "\"proposalExpiry\":86400" "\"proposalExpiry\":0" allowanceFields),
            initiativeDocument (Text.replace "\"evaluationsPerWindow\":10" "\"evaluationsPerWindow\":0" allowanceFields),
            initiativeDocument (Text.replace "\"ModelAttempts\":1," "" allowanceFields),
            initiativeDocument (Text.replace "\"CostMicroUsd\":\"unbounded\"" "\"CostMicroUsd\":9" allowanceFields),
            initiativeDocument (Text.replace "\"sources\":[\"chat-fixture\"]" "\"sources\":[]" allowanceFields),
            initiativeDocument (Text.replace "agent_proposer" "proposer" allowanceFields)
          ]
          \value -> (run [("SHIKIGAMI_INITIATIVES", value)]).exitCode @?= resolutionExitCode
    ]
  where
    settings = initiativePack.settings
    options = ConfigOptions {configPaths = [], namedSources = [], overrides = [], diagnosticMode = NoDiagnostic}
    run environment =
      appConfigRunWith settings AdminRole options (Right []) (environmentSource (either (error . Text.unpack) id (environmentBindingsWith settings)) (envSnapshot environment))
    resolved environment =
      let attempt = run environment
       in maybe (assertFailure (Text.unpack attempt.standardError)) pure attempt.resolved
    initiativeDocument fields = "{\"observers\":[{" <> fields <> "}]}"
    allowanceFields :: Text
    allowanceFields =
      "\"principal\":\"agent_proposer\",\"sources\":[\"chat-fixture\"],\"minimumExcerptLength\":5,\"evaluation\":{\"limits\":{\"ActiveWork\":1,\"ModelAttempts\":1,\"Tokens\":\"unbounded\",\"CostMicroUsd\":\"unbounded\"},\"cutoff\":3600},\"evaluationsPerWindow\":10,\"proposalsPerWindow\":5,\"notificationsPerWindow\":5,\"window\":3600,\"proposalExpiry\":86400,\"rejectionSuppression\":604800,\"notices\":{\"kizashiRecipient\":\"recipient_ops\"}"

-- | The @proposals@ verb keeps the commands and options it had as a kernel
-- verb.
verbTests :: TestTree
verbTests =
  testGroup
    "the proposals verb"
    [ testCase "its commands parse their documented options" do
        forM_
          [ ["policy", "install", "--file", "policy.json", "--json"],
            ["policy", "revoke", "shikigami_standing_policy_x", "--expected-revision", "0", "--json"],
            ["policy", "list", "--principal", "agent_p", "--after", "x", "--limit", "5", "--json"],
            ["list", "--principal", "agent_p", "--status", "pending", "--after", "x", "--limit", "5", "--json"],
            ["inspect", "--json", "--fail-when-exhausted"],
            ["candidates", "--principal", "agent_p", "--since", "2026-11-04T00:00:00Z", "--after", "x", "--limit", "5", "--json"],
            ["admissions", "--policy", "x", "--after", "y", "--limit", "5", "--json"],
            ["prune", "--before", "2026-11-04T00:00:00Z", "--batch", "10", "--json"]
          ]
          \arguments -> case Options.execParserPure Options.defaultPrefs proposals arguments of
            Options.Success _ -> pure ()
            _ -> assertFailure (unwords arguments <> " did not parse"),
      testCase "its commands refuse missing required options" do
        forM_
          [ ["policy", "install"],
            ["policy", "revoke", "x"],
            ["candidates"],
            ["prune"],
            ["prune", "--before", "yesterday"]
          ]
          \arguments -> case Options.execParserPure Options.defaultPrefs proposals arguments of
            Options.Failure _ -> pure ()
            _ -> assertFailure (unwords arguments <> " was admitted")
    ]
  where
    proposals = case initiativePack.adminVerbs of
      [verb] -> verb.parser
      _ -> error "the pack contributes exactly one verb"

manifestTests :: TestTree
manifestTests =
  testGroup
    "shipped manifest"
    [ testCase "the proposer loads, and only a composition with the pack can run it" do
        declaration <- loadAgent "agents/proposer.dhall" >>= either (assertFailure . show) pure
        composed <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack, initiativePack])
        stock <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack])
        flowDeclarationErrors composed declaration @?= []
        assertBool "the stock composition refuses it" (any ("unknown flow" `Text.isPrefixOf`) (flowDeclarationErrors stock declaration))
    ]

-- | The golden label inventory. keiro-diff cannot see a label declared outside
-- the core workflow specification, so the four paths of the flow are run
-- through the real agent-run workflow and read back from the journal.
labelTests :: DatabaseFixture -> TestTree
labelTests fixture =
  testGroup
    "durable labels"
    [ testCase "every path of the flow journals exactly the golden labels, each the pack's own" do
        accepted <- withProposing fixture defaultOptions \h -> do
          _ <- deliver h "act-1" "thread-1" plainReport
          _ <- drain h
          settle h
          h.asks >>= \case
            [ask] -> approve h ask
            other -> assertFailure ("expected one ask, got " <> show (length other))
          journaledLabels h
        declined <- withProposing fixture defaultOptions \h -> do
          _ <- deliver h "act-1" "thread-1" "planted [stub:not-actionable] so the answer declines the work"
          _ <- drain h
          journaledLabels h
        admitted <- withProposing fixture defaultOptions \h -> do
          _ <- installTerms h defaultTerms
          _ <- deliver h "act-1" "thread-1" plainReport
          _ <- drain h
          settle h
          journaledLabels h
        refused <- withProposing fixture defaultOptions \h -> do
          _ <- installTerms h defaultTerms
          let withoutCreation = h {deps = h.deps & #objectives .~ Just (h.objectiveRuntime & #settings . #agentCreation .~ [])} :: Proposing
          _ <- deliver h "act-1" "thread-1" plainReport
          _ <- drain withoutCreation
          settle withoutCreation
          journaledLabels h
        let labels = sort (Set.toList (Set.fromList (filter mentionsPack (accepted <> declined <> admitted <> refused))))
        golden <- Text.lines <$> TextIO.readFile "test/golden/labels.txt"
        assertEqual "the pack's durable labels changed; review test/golden/labels.txt" golden labels
        forM_ labels \label -> assertBool (Text.unpack label <> " is not prefixed with the pack's name") (owned label)
    ]
  where
    mentionsPack label = "initiative" `Text.isInfixOf` label
    -- The prefixes the kernel's capability interpreters put before a body's key.
    kernelPrefixes = ["decision-prepare-", "decision-result-", "objectives-", "emit-signal-", "emit-signal:", "flow-", "child:"]
    owned label = any (`Text.isPrefixOf` label) ("initiative-" : map (<> "initiative-") kernelPrefixes)
