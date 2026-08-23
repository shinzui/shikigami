module Shikigami.SinkIntentSpec (tests) where

import Data.Aeson (Value, eitherDecodeStrict, encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Foldable (traverse_)
import Data.Time (UTCTime (..), fromGregorian)
import Keiro.Integration.Event (IntegrationEvent (..))
import Shikigami.Agent.Decl
  ( Priority (High),
    RecipientFrom (SubjectOwner),
    SignalType (Alert),
    Sink (..),
  )
import Shikigami.Sink.Intent
  ( SinkIntent (..),
    decodeSinkIntentEvent,
    sinkIntentEvent,
  )
import Shikigami.Sink.Types (DanwaTarget (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "SinkIntent"
    [ testCase "round-trips every sink constructor through the outbox event" do
        traverse_ assertRoundTrip representativeSinks,
      testCase "canonical intent encodes to the pinned wire bytes" do
        encode (intentFor canonicalSink) @?= canonicalWireBytes,
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
    { agent = "at-risk-watch",
      principalId = Nothing,
      runId = "run_1",
      ordinal = 0,
      occurredAt = Just sampleTime,
      danwaTarget = Just DanwaTarget {conversationId = "conv_1", parentMessageId = Nothing},
      resolvedRecipient = Nothing,
      sink,
      output = outputValue
    }

representativeSinks :: [Sink]
representativeSinks =
  [ KawaDigest {subjectType = "customer", verb = "relationship.at_risk"},
    canonicalSink,
    ReiAction {intentionId = "intention_01sink", note = "Escalate the customer risk"},
    DanwaConversation {topic = "At-risk customer review"},
    ChannelEgress {channel = "intercom", action = "reply_to_conversation", conversationKey = Nothing}
  ]

canonicalSink :: Sink
canonicalSink =
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

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 15) 43200

canonicalWireBytes :: LazyByteString.ByteString
canonicalWireBytes =
  LazyChar8.pack
    "{\"agent\":\"at-risk-watch\",\"danwaTarget\":{\"conversationId\":\"conv_1\",\"parentMessageId\":null},\"occurredAt\":\"2026-07-15T12:00:00Z\",\"ordinal\":0,\"output\":{\"summary\":\"x\"},\"runId\":\"run_1\",\"sink\":{\"defaultRecipient\":\"ops\",\"extraContextTags\":[\"a\"],\"importance\":7,\"intentTemplate\":\"escalate\",\"priority\":\"High\",\"recipientFrom\":\"SubjectOwner\",\"signalType\":\"Alert\",\"source\":\"shikigami\",\"tag\":\"KizashiSignal\"}}"
