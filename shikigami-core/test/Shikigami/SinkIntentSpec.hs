module Shikigami.SinkIntentSpec (tests) where

import Data.Aeson (Value, eitherDecodeStrict, encode, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Foldable (traverse_)
import Data.KindID.V7 qualified as KindID
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Data.UUID qualified as UUID
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.Id qualified as SinkSession
import Shikigami.Agent.Name qualified as Name
import Shikigami.Agent.Principal (AgentIdentity (UnresolvedLegacyIdentity, VerifiedIdentity), mkAgentPrincipal)
import Shikigami.Fixture.RawOutput (rawOutput)
import Shikigami.Output (OutputDecl)
import Shikigami.Sink.Coordinate (parseSinkOrdinal, parseSinkSession, sinkOrdinalInt, zeroSinkOrdinal)
import Shikigami.Sink.Delivery qualified as Delivery
import Shikigami.Sink.Intent
  ( SinkIntent (..),
    decodeSinkIntentEvent,
    sinkIntentEvent,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "SinkIntent"
    [ testCase "native session parsing checks UUID version and variant without clock admission" do
        traverse_
          ( \uuid ->
              let raw = KindID.toText (KindID.decorateKindID uuid :: SinkSession.SessionId)
               in case parseSinkSession raw of
                    Left _ -> pure ()
                    Right _ -> assertFailure "invalid native UUID domain admitted"
          )
          [UUID.fromWords 0 0x4000 0x80000000 1, UUID.fromWords 0 0x7000 0 1],
      testCase "sink ordinals retain the exact SQL range without numeric coercion" do
        fmap sinkOrdinalInt (parseSinkOrdinal 0) @?= Right 0
        fmap sinkOrdinalInt (parseSinkOrdinal 2147483647) @?= Right 2147483647
        traverse_ (\value -> case parseSinkOrdinal value of Left _ -> pure (); Right _ -> assertFailure "invalid ordinal admitted") [-1, 2147483648, toInteger (maxBound :: Int) + 1],
      testCase "complete queued intents reject malformed admitted coordinates" do
        case Aeson.toJSON (intentFor canonicalSink) of
          Aeson.Object fields ->
            traverse_
              ( \(key, invalid) ->
                  case Aeson.fromJSON @SinkIntent (Aeson.Object (KeyMap.insert key invalid fields)) of
                    Aeson.Error _ -> pure ()
                    Aeson.Success _ -> assertFailure "malformed sink coordinate admitted"
              )
              [("agent", Aeson.String ""), ("runId", Aeson.String ""), ("runId", Aeson.String "run_1"), ("runId", Aeson.String "kioku_memory_01kvxa7d2cezhs874g3n8dfgme"), ("ordinal", Aeson.Number (-1)), ("ordinal", Aeson.Number 2147483648), ("ordinal", Aeson.Number 0.5)]
          _ -> assertFailure "intent must encode as an object",
      testCase "receipt coordinates retain legacy opaque bytes and substep spelling" do
        traverse_
          ( \raw -> do
              Delivery.sinkMessageIdText (Delivery.sinkMessageId raw) @?= raw
              Delivery.receiptKeyText (Delivery.deliveryReceiptKey raw) @?= raw
              Delivery.receiptKeyText (Delivery.subReceiptKey raw "conv") @?= raw <> "#conv"
          )
          ["", "legacy:step", "a#b", "日本"],
      testCase "round-trips representative output kinds through the outbox event" do
        traverse_ assertRoundTrip representativeSinks,
      testCase "canonical intent encodes to the pinned wire bytes" do
        encode (intentFor canonicalSink) @?= canonicalWireBytes,
      testCase "channel.egress round-trips only its resolved address" do
        let encoded = encode egressIntent
        eitherDecodeStrict (LazyByteString.toStrict encoded) @?= Right egressIntent
        let strict = LazyByteString.toStrict encoded
        ByteString.isInfixOf "\"conversationKey\":\"conv_55012\"" strict @?= True
        ByteString.isInfixOf "\"triggeringActivityId\":\"act_1\"" strict @?= True
        ByteString.isInfixOf "\"activity\":" strict @?= False,
      -- The enqueuing run rides on the intent so the publisher records the
      -- delivery against it (plan 135, M6); an intent written before has none.
      testCase "an intent carries its enqueuing run, and one without it still decodes" do
        let withRun = (intentFor canonicalSink) {run = Just (WorkflowId "run-workflow-1")}
            strict = LazyByteString.toStrict (encode withRun)
        ByteString.isInfixOf "\"run\":\"run-workflow-1\"" strict @?= True
        eitherDecodeStrict strict @?= Right withRun
        eitherDecodeStrict (LazyByteString.toStrict canonicalWireBytes) @?= Right (intentFor canonicalSink),
      testCase "the integration-event identity stays stable" do
        let IntegrationEvent {eventType, schemaVersion} = eventFor (intentFor canonicalSink)
        eventType @?= "shikigami.sink.dispatch-requested"
        schemaVersion @?= 1
    ]

assertRoundTrip :: OutputDecl -> IO ()
assertRoundTrip sink = do
  let intent = intentFor sink
  case decodeSinkIntentEvent (eventFor intent) of
    Left err -> assertFailure ("sink intent did not decode: " <> show err)
    Right decoded -> decoded @?= intent

eventFor :: SinkIntent -> IntegrationEvent
eventFor = sinkIntentEvent "sink-intent-spec:message" "run_1" sampleTime Nothing

intentFor :: OutputDecl -> SinkIntent
intentFor output =
  SinkIntent
    { agent = either (error . show) id (Name.mkAgentName "at-risk-watch"),
      identity = UnresolvedLegacyIdentity,
      runId = sinkSessionFixture,
      run = Nothing,
      ordinal = zeroSinkOrdinal,
      occurredAt = Just sampleTime,
      output,
      address = Aeson.Null,
      result = outputValue
    }

egressIntent :: SinkIntent
egressIntent =
  SinkIntent
    { agent = either (error . show) id (Name.mkAgentName "channel-reply"),
      identity = VerifiedIdentity (either (error . show) id (mkAgentPrincipal "agent_channel_reply")),
      runId = sinkSessionFixture,
      run = Nothing,
      ordinal = zeroSinkOrdinal,
      occurredAt = Just sampleTime,
      output = egressOutput,
      address = Aeson.object [("conversationKey", Aeson.String "conv_55012"), ("triggeringActivityId", Aeson.String "act_1")],
      result = outputValue
    }

-- | The Kikan kinds as the kernel carries them: a kind and its configuration.
representativeSinks :: [OutputDecl]
representativeSinks =
  [ rawOutput "kawa.digest" ["subjectType" .= text "customer", "verb" .= text "relationship.at_risk"],
    canonicalSink,
    rawOutput "rei.action" ["intentionId" .= text "intention_01sink", "note" .= text "Escalate the customer risk"],
    rawOutput "danwa.conversation" ["topic" .= text "At-risk customer review", "thread" .= Aeson.object ["conversationId" .= text "conv_1"]],
    egressOutput
  ]

egressOutput :: OutputDecl
egressOutput = rawOutput "channel.egress" ["channel" .= text "intercom", "action" .= text "reply_to_conversation", "conversationKey" .= Aeson.Null]

canonicalSink :: OutputDecl
canonicalSink =
  rawOutput
    "kizashi.signal"
    [ "source" .= text "shikigami",
      "signalType" .= text "Alert",
      "priority" .= text "High",
      "importance" .= (7 :: Int),
      "recipientFrom" .= text "SubjectOwner",
      "defaultRecipient" .= text "ops",
      "intentTemplate" .= text "escalate",
      "extraContextTags" .= [text "a"]
    ]

text :: Text -> Text
text = id

outputValue :: Value
outputValue = either error id (eitherDecodeStrict "{\"summary\":\"x\"}")

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 15) 43200

canonicalWireBytes :: LazyByteString.ByteString
canonicalWireBytes =
  LazyChar8.pack
    "{\"address\":null,\"agent\":\"at-risk-watch\",\"occurredAt\":\"2026-07-15T12:00:00Z\",\"ordinal\":0,\"output\":{\"config\":{\"defaultRecipient\":\"ops\",\"extraContextTags\":[\"a\"],\"importance\":7,\"intentTemplate\":\"escalate\",\"priority\":\"High\",\"recipientFrom\":\"SubjectOwner\",\"signalType\":\"Alert\",\"source\":\"shikigami\"},\"kind\":\"kizashi.signal\"},\"result\":{\"summary\":\"x\"},\"runId\":\"kioku_session_01kvxa7d2cezhs874g3n8dfgme\"}"

sinkSessionFixture :: SinkSession.SessionId
sinkSessionFixture = either (error . show) id (parseSinkSession "kioku_session_01kvxa7d2cezhs874g3n8dfgme")
