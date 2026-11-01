module Shikigami.SinkIntentSpec (tests) where

import Data.Aeson (Value, eitherDecodeStrict, encode)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Foldable (traverse_)
import Data.KindID.V7 qualified as KindID
import Data.Time (UTCTime (..), fromGregorian)
import Data.UUID qualified as UUID
import Keiro.Integration.Event (IntegrationEvent (..))
import Kioku.Id qualified as SinkSession
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl
  ( Priority (High),
    RecipientFrom (SubjectOwner),
    SignalType (Alert),
    Sink (..),
  )
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name qualified as Name
import Shikigami.Agent.Principal (AgentIdentity (UnresolvedLegacyIdentity, VerifiedIdentity), mkAgentPrincipal)
import Shikigami.Sink.Coordinate (parseSinkOrdinal, parseSinkSession, sinkOrdinalInt, zeroSinkOrdinal)
import Shikigami.Sink.Delivery qualified as Delivery
import Shikigami.Sink.Intent
  ( SinkIntent (..),
    decodeSinkIntentEvent,
    sinkIntentEvent,
  )
import Shikigami.Sink.Types (DanwaTarget (..))
import Shikigami.Trigger.Schedule (parseCron)
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
      testCase "round-trips every sink constructor through the outbox event" do
        traverse_ assertRoundTrip representativeSinks,
      testCase "canonical intent encodes to the pinned wire bytes" do
        encode (intentFor canonicalSink) @?= canonicalWireBytes,
      testCase "ChannelEgress round-trips only its resolved metadata" do
        let encoded = encode egressIntent
        eitherDecodeStrict (LazyByteString.toStrict encoded) @?= Right egressIntent
        let strict = LazyByteString.toStrict encoded
        ByteString.isInfixOf "\"conversationKey\":\"conv_55012\"" strict @?= True
        ByteString.isInfixOf "\"triggeringActivityId\":\"act_1\"" strict @?= True
        ByteString.isInfixOf "\"activity\":" strict @?= False,
      testCase "the integration-event identity stays stable" do
        let IntegrationEvent {eventType, schemaVersion} = eventFor (intentFor canonicalSink)
        eventType @?= "shikigami.sink.dispatch-requested"
        schemaVersion @?= 1
    ]

assertRoundTrip :: Sink -> IO ()
assertRoundTrip sink = do
  let intent = intentFor sink
  case decodeSinkIntentEvent (eventFor intent) of
    Left err -> assertFailure ("sink intent did not decode: " <> show err)
    Right decoded -> decoded @?= intent

eventFor :: SinkIntent -> IntegrationEvent
eventFor = sinkIntentEvent "sink-intent-spec:message" "run_1" sampleTime Nothing

intentFor :: Sink -> SinkIntent
intentFor sink =
  SinkIntent
    { agent = either (error . show) id (Name.mkAgentName "at-risk-watch"),
      identity = UnresolvedLegacyIdentity,
      runId = sinkSessionFixture,
      ordinal = zeroSinkOrdinal,
      occurredAt = Just sampleTime,
      danwaTarget = Just DanwaTarget {conversationId = "conv_1", parentMessageId = Nothing},
      resolvedRecipient = Nothing,
      conversationKey = Nothing,
      triggeringActivityId = Nothing,
      sink,
      output = outputValue
    }

egressIntent :: SinkIntent
egressIntent =
  SinkIntent
    { agent = either (error . show) id (Name.mkAgentName "channel-reply"),
      identity = VerifiedIdentity (either (error . show) id (mkAgentPrincipal "agent_channel_reply")),
      runId = sinkSessionFixture,
      ordinal = zeroSinkOrdinal,
      occurredAt = Just sampleTime,
      danwaTarget = Nothing,
      resolvedRecipient = Nothing,
      conversationKey = Just "conv_55012",
      triggeringActivityId = Just "act_1",
      sink = ChannelEgress {channel = declarationCoordinate ("intercom"), action = declarationCoordinate ("reply_to_conversation"), conversationKey = fmap declarationCoordinate (Nothing)},
      output = outputValue
    }

representativeSinks :: [Sink]
representativeSinks =
  [ KawaDigest {subjectType = activityCoordinate ("customer"), verb = activityCoordinate ("relationship.at_risk")},
    canonicalSink,
    ReiAction {intentionId = declarationCoordinate ("intention_01sink"), note = "Escalate the customer risk"},
    DanwaConversation {topic = "At-risk customer review"},
    ChannelEgress {channel = declarationCoordinate ("intercom"), action = declarationCoordinate ("reply_to_conversation"), conversationKey = fmap declarationCoordinate (Nothing)}
  ]

canonicalSink :: Sink
canonicalSink =
  KizashiSignal
    { source = activityCoordinate ("shikigami"),
      signalType = Alert,
      priority = High,
      importance = either (error . show) id (parseSignalImportance (7)),
      recipientFrom = SubjectOwner,
      defaultRecipient = fmap declarationCoordinate (Just "ops"),
      intentTemplate = "escalate",
      extraContextTags = ["a"]
    }

outputValue :: Value
outputValue = either error id (eitherDecodeStrict "{\"summary\":\"x\"}")

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 15) 43200

canonicalWireBytes :: LazyByteString.ByteString
canonicalWireBytes =
  LazyChar8.pack
    "{\"agent\":\"at-risk-watch\",\"danwaTarget\":{\"conversationId\":\"conv_1\",\"parentMessageId\":null},\"occurredAt\":\"2026-07-15T12:00:00Z\",\"ordinal\":0,\"output\":{\"summary\":\"x\"},\"runId\":\"kioku_session_01kvxa7d2cezhs874g3n8dfgme\",\"sink\":{\"defaultRecipient\":\"ops\",\"extraContextTags\":[\"a\"],\"importance\":7,\"intentTemplate\":\"escalate\",\"priority\":\"High\",\"recipientFrom\":\"SubjectOwner\",\"signalType\":\"Alert\",\"source\":\"shikigami\",\"tag\":\"KizashiSignal\"}}"

sinkSessionFixture :: SinkSession.SessionId
sinkSessionFixture = either (error . show) id (parseSinkSession "kioku_session_01kvxa7d2cezhs874g3n8dfgme")
