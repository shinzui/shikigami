{-# LANGUAGE DataKinds #-}

-- | The examples pack's own tests.
--
-- A pack owns what it journals. @keiro-diff@ cannot yet see a label declared
-- outside the core workflow specification, so the golden inventory in
-- @test/golden/labels.txt@ is this pack's stand-in: it lists every durable
-- label the pack's flows journal, and changing one is a reviewed diff here.
module Main (main) where

import Data.Aeson (Value (..), object, (.=))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack)
import FlowPack.Examples (atRiskCustomerDefinition, examplesPack)
import FlowPack.Examples.Body.AtRiskCustomer (RiskLevel (..), RiskVerdict (..), atRiskCustomerFlow, classifyRisk)
import FlowPack.Examples.Lifecycle.AtRiskCustomer (AtRiskCustomerCommand (..), atRiskCustomerLifecycle, atRiskCustomerMermaid, atRiskCustomerValidationWarnings)
import Keiki.Acceptor qualified as Acceptor
import Keiro.Workflow (StepName (..))
import Keiro.Workflow qualified as Keiro
import Kioku.Api.Types (MemoryRecord (..))
import Kioku.Id (genMemoryId)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (runStoreResource)
import Kiroku.Store.Effect.Resource (withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Shibuya.Telemetry.Effect (runTracingNoop)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..), activityCoordinate, parseActorKind)
import Shikigami.Agent.DeclarationValue (declarationCoordinate, declarationCoordinateText)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (ResolvedAgentIdentity (CompatibilityAgent))
import Shikigami.Decision.Contract (DecisionSlot (..))
import Shikigami.Flow (FlowDef (..), LifecycleDiagram (..))
import Shikigami.Flow.Acknowledgement (Ack (..), Acknowledgement (..))
import Shikigami.Flow.Builtin (builtinPack)
import Shikigami.Flow.Capability (Memory (..), Sink (..), runActivity)
import Shikigami.Flow.Decision (decisionStepNames)
import Shikigami.Flow.Pack
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase, withShikigamiMigratedSuite)
import Shikigami.Sink.Permission (SinkKind (SKizashiSignal))
import Shikigami.Sink.Types (SinkOutcome (Enqueued), SinkResult (..))
import System.FilePath ((</>))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

main :: IO ()
main = withShikigamiMigratedSuite \databaseFixture ->
  defaultMain (testGroup "flow-pack-examples" [classificationTests, lifecycleTests, compositionTests, labelTests databaseFixture])

-- ── Memory that changes a decision ──────────────────────────────────────────

-- | The at-risk-customer flow is the repository's teaching example of memory
-- changing a decision: a recalled escalation on the same subject makes an
-- otherwise calm message high risk.
classificationTests :: TestTree
classificationTests =
  testGroup
    "a recalled escalation changes the at-risk verdict"
    [ testCase "a calm message about a previously escalated subject is high risk" do
        let verdict = classifyRisk (activityFor "tkt_42" (object [])) [escalationMemory "tkt_42"] calmPayload
        verdict.level @?= HighRisk
        verdict.rationale @?= "prior escalation on this subject: customer relationship at risk",
      testCase "the same message with nothing recalled is unchanged" do
        let verdict = classifyRisk (activityFor "tkt_42" (object [])) [] calmPayload
        verdict.level @?= LowRisk
        verdict.rationale @?= "no high-risk signal detected",
      testCase "an escalation on another subject does not carry over" do
        (classifyRisk (activityFor "tkt_42" (object [])) [escalationMemory "tkt_99"] calmPayload).level @?= LowRisk,
      testCase "a memory that merely mentions the subject is not an escalation" do
        (classifyRisk (activityFor "tkt_42" (object [])) [memoryWith "tkt_42 asked about invoicing"] calmPayload).level @?= LowRisk,
      testCase "the words of the message alone can raise the risk" do
        (classifyRisk (activityFor "tkt_42" (object [])) [] churnPayload).level @?= HighRisk
    ]

-- ── The lifecycle diagram ───────────────────────────────────────────────────

lifecycleTests :: TestTree
lifecycleTests =
  testGroup
    "the at-risk customer lifecycle"
    [ testCase "is well-formed" do
        assertEqual "keiki validation warnings" [] atRiskCustomerValidationWarnings
        atRiskCustomerDefinition.lifecycle.validationWarnings @?= [],
      testCase "accepts exactly the branches the flow takes" do
        let accepts = Acceptor.accepts (Acceptor.inputAcceptor atRiskCustomerLifecycle)
        assertBool "low-risk branch is accepted" (accepts [ClassifyLowRisk])
        assertBool "acknowledged high-risk branch is accepted" (accepts [ClassifyHighRisk, Acknowledge])
        assertBool "timed-out high-risk branch is accepted" (accepts [ClassifyHighRisk, DeadlineExpired])
        assertBool "acknowledgement cannot precede classification" (not (accepts [Acknowledge])),
      testCase "renders the states an operator reads" do
        mapM_
          (\needle -> assertBool (Text.unpack needle) (needle `Text.isInfixOf` atRiskCustomerMermaid))
          ["stateDiagram-v2", "AwaitingAck", "Escalated"]
        atRiskCustomerDefinition.lifecycle.mermaid @?= atRiskCustomerMermaid
    ]

-- ── Composition ─────────────────────────────────────────────────────────────

compositionTests :: TestTree
compositionTests =
  testGroup
    "composition"
    [ testCase "the pack composes beside the builtin pack and owns its flow" do
        registry <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack, examplesPack])
        mapM_
          (\name -> fmap (flowPackNameText . (.pack)) (lookupFlow registry (declarationCoordinate name)) @?= Just "examples")
          ["at-risk-customer", "objective-example", "shikumi-decision-example", "shikumi-judgment-example", "delegation-proof"]
        flowPackNameText <$> registeredPacks registry @?= ["builtin", "examples"],
      testCase "the builtin pack alone does not have the flow" do
        registry <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack])
        mapM_
          (\name -> assertBool (Text.unpack name <> " left the core") (null (lookupFlow registry (declarationCoordinate name))))
          ["at-risk-customer", "objective-example", "shikumi-decision-example", "shikumi-judgment-example", "delegation-proof"],
      testCase "the pack's decision programs and their retained codecs compose with the kernel's" do
        registry <- either (assertFailure . show) pure (composeFlowRegistry [builtinPack, examplesPack])
        mapM_
          (\declared -> assertBool "a declared slot resolves its program" (not (null declared.programs)))
          [slot | entry <- registeredFlows registry, entry.pack == examplesPack.name, slot <- entry.flow.definition.decisionSlots],
      testCase "composing the pack twice is refused" do
        case composeFlowRegistry [builtinPack, examplesPack, examplesPack] of
          Left errors -> assertBool "the duplicate pack is named" (DuplicatePackName examplesPack.name `elem` NonEmpty.toList errors)
          Right _ -> assertFailure "a pack composed twice must be refused"
    ]

-- ── The golden label inventory ──────────────────────────────────────────────

labelTests :: DatabaseFixture -> TestTree
labelTests databaseFixture =
  testGroup
    "durable labels"
    [ testCase "every branch of the flow journals exactly the golden labels" do
        journaled <- sort . Set.toList <$> journaledLabels databaseFixture branches
        golden <- Text.lines <$> TextIO.readFile ("test" </> "golden" </> "labels.txt")
        assertEqual "the pack's durable labels changed; review test/golden/labels.txt" golden journaled,
      testCase "every label is the pack's own or a kernel capability label over the pack's key" do
        journaled <- Set.toList <$> journaledLabels databaseFixture branches
        assertBool "the flow journals something" (not (null journaled))
        mapM_ (\label -> assertBool (Text.unpack label <> " is not prefixed with the pack's name") (owned label)) journaled
    ]
  where
    packName = flowPackNameText examplesPack.name <> "-"
    -- The prefixes the kernel's capability interpreters put before a body's key.
    kernelPrefixes = ["recall-", "remember-", "emit-signal-", "flow-", "decision-prepare-", "decision-result-"]
    owned label = any (`Text.isPrefixOf` label) (packName : map (<> packName) kernelPrefixes)
    branches =
      [ (calmPayload, TimedOut),
        (churnPayload, Acknowledged (String "on it")),
        (churnPayload, Declined "not ours"),
        (churnPayload, TimedOut)
      ]

-- | Run every branch of the flow body and return the labels it journals.
--
-- The body's own steps run under the real keiro workflow runtime against a
-- fresh database, and are read back from the journal: keiro has no in-memory
-- interpreter, and the journal is the durable contract the inventory is
-- about. The kernel capabilities are recording interpreters that name their
-- steps exactly as the kernel's interpreters do.
journaledLabels :: DatabaseFixture -> [(Value, Ack)] -> IO (Set.Set Text)
journaledLabels databaseFixture branches =
  withShikigamiFreshDatabase databaseFixture \connectionString -> do
    let settings = defaultConnectionSettings connectionString
    seen <- newIORef Set.empty
    journals <- withStore settings \_ ->
      mapM
        ( \(ordinal, (payload, answer)) -> do
            let workflowId = Keiro.WorkflowId ("label-inventory-" <> Text.pack (show ordinal))
            result <-
              runEff
                . runTracingNoop
                . runErrorNoCallStack @StoreError
                . withKirokuStore settings
                . runStoreResource
                $ do
                  _ <-
                    Keiro.runWorkflowWith Keiro.defaultWorkflowRunOptions inventoryWorkflow workflowId
                      . runActivity (activityFor "tkt_42" payload)
                      . recordingMemory seen
                      . recordingSink seen
                      . recordingAcknowledgement seen answer
                      $ atRiskCustomerFlow payload
                  Keiro.loadStepIndex inventoryWorkflow workflowId 0
            either (assertFailure . show) (pure . Map.keysSet) result
        )
        (zip [0 :: Int ..] branches)
    captured <- readIORef seen
    -- Names beginning with two underscores are keiro's own runtime markers.
    pure (Set.filter (not . Text.isPrefixOf "__") (Set.unions (captured : declaredDecisionLabels : journals)))
  where
    inventoryWorkflow = Keiro.WorkflowName "flow-pack-examples.label-inventory"

-- | The two journal steps of every decision slot a flow of the pack declares.
-- They follow from the pack value: a decision journals
-- @decision-prepare-\<site\>@ and @decision-result-\<site\>@.
--
-- The objective and delegation keys of the example flows are not derived
-- here. Walking those bodies needs replies only the kernel's stores can
-- build, and keiro offers no store-free workflow runtime (keiro IR-61).
declaredDecisionLabels :: Set.Set Text
declaredDecisionLabels =
  Set.fromList
    [ label
    | packFlow <- examplesPack.flows,
      slot <- packFlow.definition.decisionSlots,
      let (StepName prepare, StepName result) = decisionStepNames slot.label,
      label <- [prepare, result]
    ]

record :: (IOE :> es) => IORef (Set.Set Text) -> Text -> Eff es ()
record seen label = liftIO (modifyIORef' seen (Set.insert label))

recordingMemory :: (IOE :> es) => IORef (Set.Set Text) -> Eff (Memory : es) a -> Eff es a
recordingMemory seen = interpret \_ -> \case
  Recall label _ -> record seen ("recall-" <> declarationCoordinateText label) >> pure []
  Remember label _ _ -> record seen ("remember-" <> declarationCoordinateText label) >> liftIO genMemoryId

recordingSink :: (IOE :> es) => IORef (Set.Set Text) -> Eff (Sink : es) a -> Eff es a
recordingSink seen = interpret \_ -> \case
  EmitSignal label _ _ -> record seen ("emit-signal-" <> declarationCoordinateText label) >> pure (SinkResult SKizashiSignal (Enqueued (declarationCoordinate "recorded")))
  _ -> error "the at-risk body emits one signal at a time"

recordingAcknowledgement :: (IOE :> es) => IORef (Set.Set Text) -> Ack -> Eff (Acknowledgement : es) a -> Eff es a
recordingAcknowledgement seen answer = interpret \_ -> \case
  AwaitAcknowledgement (Keiro.StepName label) _ -> record seen ("flow-" <> label) >> pure answer
  AwaitAcknowledgementWithin (Keiro.StepName label) _ _ -> record seen ("flow-" <> label) >> pure answer

-- ── Fixtures ────────────────────────────────────────────────────────────────

calmPayload :: Value
calmPayload = object ["text" .= ("customer says thanks, all good" :: Text)]

churnPayload :: Value
churnPayload = object ["text" .= ("we are going to cancel our plan" :: Text)]

activityFor :: Text -> Value -> ActivityEnvelope
activityFor ticket payload =
  ActivityEnvelope
    { activityId = activityCoordinate ("act_" <> ticket),
      occurredAt = activityCoordinate "2026-07-15T12:00:00Z",
      source = activityCoordinate "shinzui/shikigami",
      actor = Actor {kind = either (error . show) id (parseActorKind "human"), id = activityCoordinate "someone", session = Nothing},
      subject = Subject {kind = activityCoordinate "ticket", subjectId = activityCoordinate ticket},
      verb = activityCoordinate "ticket.updated",
      payload,
      contextRefs = [],
      idempotencyKey = activityCoordinate ("act_" <> ticket)
    }

escalationMemory :: Text -> MemoryRecord
escalationMemory ticket = memoryWith (ticket <> " escalated after acknowledgement timeout")

memoryWith :: Text -> MemoryRecord
memoryWith prose =
  MemoryRecord
    { memoryId = "mem_prior_learning_1",
      agentId = "at-risk-customer",
      sessionId = Nothing,
      scope = agentScope (CompatibilityAgent (either (error . show) id (mkAgentName "at-risk-customer"))),
      memoryType = "pattern",
      content = prose,
      priority = 100,
      confidence = "medium",
      tags = Set.empty,
      status = "active",
      createdAt = UTCTime (fromGregorian 2026 7 15) 0
    }
