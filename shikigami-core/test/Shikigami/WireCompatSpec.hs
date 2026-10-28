-- | Literal durable-wire fixtures. The release/record migration preserved the
-- original bytes. Plan 65 then deliberately established the generated queue
-- envelope under ADR 0027's unused pre-v1 exception. The old bare queue value
-- remains a rejection fixture; other protocol fixtures retain their contracts.
module Shikigami.WireCompatSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Aeson (FromJSON, Value (Object), eitherDecodeStrict, encode, toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Keiro.Workflow.Types (WorkflowId (..), mkWorkflowId)
import Shibuya.Core.Types (Attempt (..), Envelope (..), mkEnvelope)
import Shikigami.Agent.Decl
  ( Priority (High),
    RecipientFrom (SubjectOwner),
    SignalType (Alert),
    Sink (..),
  )
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (AgentIdentity (UnresolvedLegacyIdentity), compatibilityIdentity)
import Shikigami.Agent.Run.Key (RunKey (..))
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (TriggeredByStream), runJobWorkflowId)
import Shikigami.Agent.Workflow (StepResult (..))
import Shikigami.Capability.Catalog (CapabilityResolutionError)
import Shikigami.Capability.Overlay
  ( CapabilityDescriptor (..),
    CapabilityOperationClass (Observation),
    CapabilityToolDescriptor (..),
    ResolvedCapabilitySet,
    mkCapabilityId,
    mkCapabilityRevision,
    mkResolvedCapabilitySet,
  )
import Shikigami.Execution.Identity (ExecutionRootId (..))
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Sink.Intent (SinkIntent (..))
import Shikigami.Sink.Permission (SinkKind (SKizashiSignal, SReiAction))
import Shikigami.Sink.Types
  ( DanwaTarget (..),
    SinkOutcome (Delivered, SkippedLifecycle, Stubbed),
    SinkResult (..),
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "wire compatibility"
    [ identityBoundaryTests,
      queueTests,
      stepResultTests,
      capabilityResolutionTests,
      outboxTests,
      deliveryAttemptTests
    ]

-- ---------------------------------------------------------------------------
-- Journaled agent-run step values
-- ---------------------------------------------------------------------------

-- | The agent-run workflow journals its @open-session@, @record@, @complete@ and
-- @fail-session@ steps, and those journals outlive the binary that wrote them.
-- Teaching those steps to record a kioku refusal must not change what a step
-- that succeeded writes, or a workflow parked before the change stops replaying.
-- Per ADR 0011 the produced value keeps the bare encoding and only a refusal
-- introduces a key.
stepResultTests :: TestTree
stepResultTests =
  testGroup
    "agent-run step values"
    [ testCase "a produced value encodes exactly as the bare value" do
        assertSameJson "session id" "\"ses_1\"" (encode (StepProduced ("ses_1" :: Text)))
        assertSameJson "no memory id" "null" (encode (StepProduced (Nothing :: Maybe Text)))
        assertSameJson "unit" "[]" (encode (StepProduced ())),
      testCase "a pre-refusal step value still decodes to the produced value" do
        decoded <- decodeOrFail @(StepResult Text) "\"ses_1\""
        decoded @?= StepProduced "ses_1"
        noMemory <- decodeOrFail @(StepResult (Maybe Text)) "null"
        noMemory @?= StepProduced Nothing
        unit <- decodeOrFail @(StepResult ()) "[]"
        unit @?= StepProduced (),
      testCase "a refusal round-trips and is distinguishable from a value" do
        let refused = StepRefused "opening the run's kioku session was refused: SessionInvalidLineage" :: StepResult Text
        decoded <- decodeOrFail @(StepResult Text) (LazyByteString.toStrict (encode refused))
        decoded @?= refused
    ]

-- | The capability decision is the new journaled policy snapshot. Live
-- provider registries and leases have no codec; only these public descriptors
-- cross the durable boundary.
capabilityResolutionTests :: TestTree
capabilityResolutionTests =
  testGroup
    "capability resolution step values"
    [ testCase "a successful resolved set has stable journal bytes" do
        let resolution = Right sampleCapabilityResolution :: Either CapabilityResolutionError ResolvedCapabilitySet
        assertSameJson
          "capability resolution"
          "{\"Right\":[{\"capability\":\"workspace.read\",\"revision\":\"v1\",\"tools\":[{\"name\":\"read\",\"operationClass\":\"Observation\"}]}]}"
          (encode resolution)
        decodeOrFail @(Either CapabilityResolutionError ResolvedCapabilitySet) (LazyByteString.toStrict (encode resolution))
          >>= (@?= resolution)
    ]

sampleCapabilityResolution :: ResolvedCapabilitySet
sampleCapabilityResolution =
  mkResolvedCapabilitySet
    [ CapabilityDescriptor
        { capability = either (error . show) id (mkCapabilityId "workspace.read"),
          revision = either (error . show) id (mkCapabilityRevision "v1"),
          tools = [CapabilityToolDescriptor {name = "read", operationClass = Observation}]
        }
    ]

-- ---------------------------------------------------------------------------
-- The run-job queue
-- ---------------------------------------------------------------------------

-- | Producer and consumer execute this complete generated envelope. The
-- hand-owned journal retains the domain value; it does not record the envelope.
queueTests :: TestTree
queueTests =
  testGroup
    "shikigami_run_jobs generated envelope"
    [ testCase "production encoder matches the complete envelope golden" do
        assertSameJson "run job envelope" currentRunJobEnvelope (encode (RunJobs.encodeRunJob sampleRunJob)),
      testCase "production decoder accepts the literal envelope" do
        value <- decodeOrFail @Value currentRunJobEnvelope
        RunJobs.decodeRunJob value @?= Right sampleRunJob,
      testCase "v1 jobs default to unenrolled without changing input" do
        value <- decodeOrFail @Value preResourceRunJobEnvelope
        RunJobs.decodeRunJob value @?= Right sampleRunJob,
      testCase "v1 input resembling resource metadata is never reinterpreted" do
        value <- decodeOrFail @Value preResourceRunJobEnvelope
        let input = Aeson.object ["executionRootId" Aeson..= ("forged" :: Text), "input" Aeson..= triggerPayloadValue]
            historical = case value of
              Object outer -> case KeyMap.lookup "data" outer of
                Just (Object payload) -> Object (KeyMap.insert "data" (Object (KeyMap.insert "triggerPayload" input payload)) outer)
                _ -> value
              _ -> value
        RunJobs.decodeRunJob historical @?= Right (sampleRunJob & #triggerPayload .~ input),
      testCase "enrolled jobs retain the root through the v2 queue envelope" do
        let enrolled = sampleRunJob & #executionRootId .~ Just (ExecutionRootId "root-1")
        RunJobs.decodeRunJob (RunJobs.encodeRunJob enrolled) @?= Right enrolled,
      testCase "historical journal omission remains unenrolled" do
        let value = case toJSON sampleRunJob of Object o -> Object (KeyMap.delete "executionRootId" o); other -> other
        Aeson.fromJSON @RunJob value @?= Aeson.Success sampleRunJob,
      testCase "the old bare payload is rejected" do
        value <- decodeOrFail @Value preUpgradeRunJob
        case RunJobs.decodeRunJob value of
          Left _ -> pure ()
          Right _ -> assertFailure "bare payload accepted",
      testCase "a route is required at the current domain boundary" do
        case toJSON sampleRunJob of
          Object fields -> case Aeson.fromJSON @RunJob (Object (KeyMap.delete "routeKind" fields)) of
            Aeson.Error _ -> pure ()
            Aeson.Success _ -> assertFailure "undeclared route accepted"
          _ -> assertFailure "job must be an object",
      testCase "the current journal value remains the unwrapped domain value" do
        decoded <- decodeOrFail @RunJob (LazyByteString.toStrict (encode sampleRunJob))
        decoded @?= sampleRunJob
    ]

sampleRunJob :: RunJob
sampleRunJob =
  RunJob
    { agentName = AgentName "at-risk-watch",
      identity = compatibilityIdentity "at-risk-watch",
      triggerKind = TriggeredByStream,
      routeKind = AgentWorkflowRoute,
      occurredAt = sampleTime,
      triggerPayload = triggerPayloadValue,
      idempotencyKey = RunKey "at-risk-watch:act_1",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

triggerPayloadValue :: Value
triggerPayloadValue = either error id (eitherDecodeStrict "{\"activityId\":\"act_1\"}")

preUpgradeRunJob :: ByteString
preUpgradeRunJob =
  "{\"agentName\":\"at-risk-watch\",\"delegationDepth\":null,\"idempotencyKey\":\"at-risk-watch:act_1\",\"occurredAt\":\"2026-07-15T12:00:00Z\",\"parentRunWorkflowId\":null,\"parentSessionId\":null,\"triggerKind\":\"TriggeredByStream\",\"triggerPayload\":{\"activityId\":\"act_1\"}}"

-- ---------------------------------------------------------------------------
-- The sink outbox
-- ---------------------------------------------------------------------------

-- | A 'SinkIntent' is journaled by the agent-run workflow and stored as an
-- outbox row, so rows written before the upgrade are sitting in databases now
-- and must still decode. 'SinkResult' is journaled alongside it, including the
-- deprecated 'Stubbed' outcome that
-- @docs\/plans\/16-honest-sink-handlers-real-reiaction-and-honored-declaration-fields.md@
-- will stop producing — stop /producing/, not stop /decoding/: historical rows
-- keep it forever.
outboxTests :: TestTree
outboxTests =
  testGroup
    "sink outbox rows"
    [ testCase "a pre-upgrade sink intent decodes to the same value" do
        decoded <- decodeOrFail @SinkIntent preUpgradeSinkIntent
        toJSON decoded @?= toJSON sampleSinkIntent,
      testCase "the encoder still produces the pre-upgrade bytes" do
        assertSameJson "sink intent" preUpgradeSinkIntent (encode sampleSinkIntent),
      testCase "a delivered sink result decodes" do
        decoded <- decodeOrFail @SinkResult preUpgradeDelivered
        toJSON decoded @?= toJSON (SinkResult {kind = SKizashiSignal, outcome = Delivered "sig_1"}),
      testCase "the deprecated Stubbed outcome still decodes" do
        decoded <- decodeOrFail @SinkResult preUpgradeStubbed
        toJSON decoded @?= toJSON (SinkResult {kind = SReiAction, outcome = Stubbed}),
      -- The decode above proves a pre-upgrade row parses; this proves what it
      -- parses to. A row written before recipientFrom was honored must route
      -- exactly as it did then — falling back to the declaration's own default —
      -- rather than acquiring a recipient nobody chose.
      testCase "a pre-upgrade row carries no resolved recipient" do
        SinkIntent {resolvedRecipient} <- decodeOrFail @SinkIntent preUpgradeSinkIntent
        resolvedRecipient @?= Nothing,
      testCase "a pre-upgrade row carries unresolved legacy identity" do
        SinkIntent {identity} <- decodeOrFail @SinkIntent preUpgradeSinkIntent
        identity @?= UnresolvedLegacyIdentity,
      testCase "a pre-upgrade row carries no egress metadata" do
        SinkIntent {conversationKey, triggeringActivityId} <- decodeOrFail @SinkIntent preUpgradeSinkIntent
        conversationKey @?= Nothing
        triggeringActivityId @?= Nothing,
      testCase "an intent that resolved a recipient says so" do
        let resolved = sampleSinkIntent {resolvedRecipient = Just "person:nadeem"}
        decoded <- decodeOrFail @SinkIntent (LazyByteString.toStrict (encode resolved))
        toJSON decoded @?= toJSON resolved,
      testCase "the lifecycle skip outcome round-trips without changing old outcomes" do
        let skipped = SinkResult {kind = SKizashiSignal, outcome = SkippedLifecycle "principal lifecycle is paused"}
        decoded <- decodeOrFail @SinkResult (LazyByteString.toStrict (encode skipped))
        decoded @?= skipped
    ]

sampleSinkIntent :: SinkIntent
sampleSinkIntent =
  SinkIntent
    { agent = "at-risk-watch",
      identity = UnresolvedLegacyIdentity,
      runId = "run_1",
      ordinal = 0,
      occurredAt = Just sampleTime,
      danwaTarget = Just DanwaTarget {conversationId = "conv_1", parentMessageId = Nothing},
      -- Absent, and therefore absent from the bytes below: this field was added
      -- after those rows were written, and @omitNothingFields@ is what keeps an
      -- intent that does not use it byte-identical to one that predates it.
      resolvedRecipient = Nothing,
      conversationKey = Nothing,
      triggeringActivityId = Nothing,
      sink = sampleSink,
      output = outputValue
    }

sampleSink :: Sink
sampleSink =
  KizashiSignal
    { source = "shikigami",
      signalType = Alert,
      priority = High,
      importance = 7,
      recipientFrom = SubjectOwner,
      defaultRecipient = Just "ops",
      intentTemplate = "escalate",
      extraContextTags = ["a"]
    }

outputValue :: Value
outputValue = either error id (eitherDecodeStrict "{\"summary\":\"x\"}")

preUpgradeSinkIntent :: ByteString
preUpgradeSinkIntent =
  "{\"agent\":\"at-risk-watch\",\"danwaTarget\":{\"conversationId\":\"conv_1\",\"parentMessageId\":null},\"occurredAt\":\"2026-07-15T12:00:00Z\",\"ordinal\":0,\"output\":{\"summary\":\"x\"},\"runId\":\"run_1\",\"sink\":{\"defaultRecipient\":\"ops\",\"extraContextTags\":[\"a\"],\"importance\":7,\"intentTemplate\":\"escalate\",\"priority\":\"High\",\"recipientFrom\":\"SubjectOwner\",\"signalType\":\"Alert\",\"source\":\"shikigami\",\"tag\":\"KizashiSignal\"}}"

preUpgradeDelivered :: ByteString
preUpgradeDelivered =
  "{\"kind\":\"SKizashiSignal\",\"outcome\":{\"contents\":\"sig_1\",\"tag\":\"Delivered\"}}"

preUpgradeStubbed :: ByteString
preUpgradeStubbed =
  "{\"kind\":\"SReiAction\",\"outcome\":{\"tag\":\"Stubbed\"}}"

-- ---------------------------------------------------------------------------
-- Delivery attempt numbering
-- ---------------------------------------------------------------------------

-- | @shibuya-pgmq-adapter 0.12@ converts PGMQ's one-based @read_count@ into a
-- zero-based 'Shibuya.Core.Types.Attempt' itself, so a first delivery reaches
-- the handler as attempt @0@. An application that subtracts one again does not
-- merely go negative: 'Attempt' wraps a 'Word', so @0 - 1@ underflows to
-- 'maxBound' and every first delivery looks like the most-retried message the
-- system has ever seen.
--
-- The typed consumer now receives that value as 'Keiro.PGMQ.JobContext.attempt'.
-- It deliberately leaves delivery counting to @defaultRetryPolicy@ instead of
-- maintaining an application counter, but any future diagnostic use inherits
-- an already-zero-based number and must not re-normalize it. These cases pin the
-- adapter contract and the underflow that would follow from breaking it.
deliveryAttemptTests :: TestTree
deliveryAttemptTests =
  testGroup
    "PGMQ delivery attempts"
    [ testCase "a first delivery is attempt zero, not attempt one" do
        firstDelivery @?= Attempt 0,
      testCase "normalizing an already-normalized attempt underflows" do
        -- Not a hypothetical: Attempt wraps a Word.
        firstDelivery - Attempt 1 @?= Attempt maxBound,
      testCase "an envelope carries the payload the handler decodes" do
        let Envelope {payload} = mkEnvelope "msg_1" triggerPayloadValue
        payload @?= triggerPayloadValue
    ]

-- | What @shibuya-pgmq-adapter@ hands a handler for a PGMQ row whose
-- @read_count@ is @1@.
firstDelivery :: Attempt
firstDelivery = Attempt 0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 15) 43200

decodeOrFail :: forall a. (FromJSON a) => ByteString -> IO a
decodeOrFail =
  either (assertFailure . ("fixture no longer decodes: " <>)) pure . eitherDecodeStrict @a

assertSameJson :: String -> ByteString -> LazyByteString.ByteString -> IO ()
assertSameJson label expected actual = do
  expectedValue <- either (assertFailure . (("could not decode the " <> label <> " fixture: ") <>)) pure (eitherDecodeStrict @Value expected)
  actualValue <-
    either
      (assertFailure . (("could not decode the re-encoded " <> label <> ": ") <>))
      pure
      (eitherDecodeStrict @Value (LazyByteString.toStrict actual))
  assertEqual (label <> " round-trips to the same JSON") expectedValue actualValue

identityBoundaryTests :: TestTree
identityBoundaryTests =
  testGroup
    "runtime identity boundaries"
    [ testCase "generated queue ingress rejects invalid scalar domains" do
        for_ [("agentName", Aeson.String ""), ("idempotencyKey", Aeson.String ""), ("delegationDepth", toJSON (-1 :: Int)), ("lineage", toJSON ([""] :: [Text]))] \(field, invalid) ->
          case RunJobs.encodeRunJob sampleRunJob of
            Object envelope -> case KeyMap.lookup "data" envelope of
              Just (Object payload) -> case RunJobs.decodeRunJob (Object (KeyMap.insert "data" (Object (KeyMap.insert field invalid payload)) envelope)) of
                Left _ -> pure ()
                Right _ -> assertFailure ("invalid scalar accepted: " <> show field)
              _ -> assertFailure "queue payload must be an object"
            _ -> assertFailure "queue envelope must be an object",
      testCase "a memory ID cannot enter the parent session boundary" do
        case toJSON sampleRunJob of
          Object fields -> case Aeson.fromJSON @RunJob (Object (KeyMap.insert "parentSessionId" (Aeson.String "kioku_memory_01kvxa7d2cezhs874g3n8dfgme") fields)) of
            Aeson.Error _ -> pure ()
            Aeson.Success _ -> assertFailure "cross-domain session ID accepted"
          _ -> assertFailure "job must be an object",
      testCase "structural workflow separators are rejected at decoding" do
        case toJSON sampleRunJob of
          Object fields -> case Aeson.fromJSON @RunJob (Object (KeyMap.insert "parentRunWorkflowId" (Aeson.String "parent#1") fields)) of
            Aeson.Error _ -> pure ()
            Aeson.Success _ -> assertFailure "ambiguous workflow ID accepted"
          _ -> assertFailure "job must be an object",
      testCase "a natural deduplication key derives a stable valid workflow ID" do
        let first = runJobWorkflowId sampleRunJob
        runJobWorkflowId sampleRunJob @?= first
        mkWorkflowId first.unWorkflowId @?= Right first
        case runJobWorkflowId (sampleRunJob {idempotencyKey = RunKey "another:event"}) == first of
          False -> pure ()
          True -> assertFailure "distinct run keys collided"
    ]

currentRunJobEnvelope :: ByteString
currentRunJobEnvelope = "{\"data\":{\"agentName\":\"at-risk-watch\",\"delegationBudgetId\":null,\"delegationDepth\":null,\"idempotencyKey\":\"at-risk-watch:act_1\",\"identity\":{\"agentName\":\"at-risk-watch\",\"kind\":\"compatibility\"},\"lineage\":[],\"occurredAt\":\"2026-07-15T12:00:00Z\",\"parentRunWorkflowId\":null,\"parentSessionId\":null,\"routeKind\":\"AgentWorkflowRoute\",\"triggerKind\":\"TriggeredByStream\",\"triggerPayload\":{\"executionRootId\":null,\"input\":{\"activityId\":\"act_1\"}}},\"t\":\"RunJobMessage\",\"v\":2}"

preResourceRunJobEnvelope :: ByteString
preResourceRunJobEnvelope = "{\"data\":{\"agentName\":\"at-risk-watch\",\"delegationBudgetId\":null,\"delegationDepth\":null,\"idempotencyKey\":\"at-risk-watch:act_1\",\"identity\":{\"agentName\":\"at-risk-watch\",\"kind\":\"compatibility\"},\"lineage\":[],\"occurredAt\":\"2026-07-15T12:00:00Z\",\"parentRunWorkflowId\":null,\"parentSessionId\":null,\"routeKind\":\"AgentWorkflowRoute\",\"triggerKind\":\"TriggeredByStream\",\"triggerPayload\":{\"activityId\":\"act_1\"}},\"t\":\"RunJobMessage\",\"v\":1}"
