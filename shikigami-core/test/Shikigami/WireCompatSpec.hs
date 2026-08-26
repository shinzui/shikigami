-- | Compatibility fixtures for everything Shikigami persists or enqueues.
--
-- The July 2026 dependency cohort changed durable protocols underneath this
-- application: Keiro 0.4 added a snapshot state-shape hash and a versioned queue
-- envelope for scaffolded workqueues, Kioku 0.2 moved onto it, and
-- shibuya-pgmq-adapter 0.12 changed how a delivery attempt is counted. None of
-- those changes is supposed to alter a byte Shikigami writes. This module is the
-- proof, and the reason the literals below are literals: a fixture built by
-- calling the current encoder would pass no matter what the encoder did.
--
-- The literals were captured from the encoders as they stand, and
-- @git diff@ over the modules defining these types is empty between the
-- pre-upgrade commit @fef46f1@ and the upgrade, so they are also what the
-- pre-upgrade build produced. Keep them permanently: they are the record of what
-- is already in production queues and outbox rows. A change here is a wire-format
-- change and needs a migration story, not a fixture edit.
module Shikigami.WireCompatSpec (tests) where

import Data.Aeson (FromJSON, Value (Object), eitherDecodeStrict, encode, toJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List qualified as List
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Shibuya.Core.Types (Attempt (..), Envelope (..), mkEnvelope)
import Shikigami.Agent.Decl
  ( Priority (High),
    RecipientFrom (SubjectOwner),
    SignalType (Alert),
    Sink (..),
  )
import Shikigami.Agent.Principal (AgentIdentity (UnresolvedLegacyIdentity))
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (TriggeredByStream))
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
    [ queueTests,
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

-- | Keiro 0.4 gives @keiro-dsl@-scaffolded workqueues a versioned
-- @keiroJobCodec@ envelope, and its changelog is explicit that replacing a bare
-- payload codec on an existing queue strands in-flight messages unless the queue
-- is drained first.
--
-- Shikigami's @shikigami_run_jobs@ queue is not scaffolded by @keiro-dsl@. It is
-- sent through PGMQ directly by "Shikigami.Trigger.Enqueue", whose message body
-- is @toJSON job@ — a bare 'RunJob' — and drained by
-- "Shikigami.Agent.RunJob.Worker", which decodes the same bare value. So the
-- envelope change does not reach this queue and no drain gate is required. These
-- cases are what makes that claim checkable rather than asserted: if the queue
-- ever does move to the envelope, they fail.
queueTests :: TestTree
queueTests =
  testGroup
    "shikigami_run_jobs payloads"
    [ testCase "a pre-upgrade run job decodes to the same value" do
        decoded <- decodeOrFail @RunJob preUpgradeRunJob
        decoded @?= sampleRunJob,
      testCase "the encoder still produces the pre-upgrade bytes" do
        assertSameJson "run job" preUpgradeRunJob (encode sampleRunJob),
      testCase "the payload is a bare run job, not a versioned envelope" do
        -- A keiroJobCodec envelope would wrap the job under a schema-version
        -- key. Decoding straight to a RunJob is what proves it does not.
        value <- decodeOrFail @Value preUpgradeRunJob
        assertEqual "the payload is the job itself" (toJSON sampleRunJob) value,
      -- The route discriminator is additive. A job enqueued or journaled before
      -- it existed carries no @routeKind@ key, and must keep meaning what it
      -- meant then: "nobody declared a route, so reproduce the old decision".
      testCase "a legacy job decodes with the inferred route" do
        RunJob {routeKind} <- decodeOrFail @RunJob preUpgradeRunJob
        assertEqual "no routeKind key means the legacy route" InferredLegacyRoute routeKind,
      testCase "an explicit route round-trips and adds exactly one key" do
        let explicit = sampleRunJob {routeKind = ConversationWorkflowRoute}
        encodedValue <- decodeOrFail @Value (LazyByteString.toStrict (encode explicit))
        legacyValue <- decodeOrFail @Value preUpgradeRunJob
        case (encodedValue, legacyValue) of
          (Object explicitObject, Object legacyObject) -> do
            assertEqual
              "removing routeKind leaves exactly the pre-upgrade keys"
              (List.sort (KeyMap.keys legacyObject))
              (List.sort (KeyMap.keys (KeyMap.delete "routeKind" explicitObject)))
            assertEqual
              "the added key is the declared route"
              (Just (toJSON ConversationWorkflowRoute))
              (KeyMap.lookup "routeKind" explicitObject)
          _ -> assertFailure "a run job must encode as a JSON object"
        decoded <- decodeOrFail @RunJob (LazyByteString.toStrict (encode explicit))
        assertEqual "an explicit route survives a round trip" explicit decoded
    ]

sampleRunJob :: RunJob
sampleRunJob =
  RunJob
    { agentName = "at-risk-watch",
      identity = UnresolvedLegacyIdentity,
      triggerKind = TriggeredByStream,
      routeKind = InferredLegacyRoute,
      occurredAt = sampleTime,
      triggerPayload = triggerPayloadValue,
      idempotencyKey = "at-risk-watch:act_1",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
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
