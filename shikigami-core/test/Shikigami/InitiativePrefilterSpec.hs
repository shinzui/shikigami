{-# LANGUAGE DataKinds #-}

module Shikigami.InitiativePrefilterSpec (tests) where

import Control.Exception (evaluate)
import Control.Monad (forM_, void)
import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.Execution.Resources (Envelope (..))
import Shikigami.Initiative.Intake
import Shikigami.Initiative.Settings
import Shikigami.Initiative.Source (observe, sourceKindFor)
import Shikigami.Initiative.Types hiding (AgentActor)
import Shikigami.Initiative.Types qualified as Initiative
import Shikigami.Objective.Keys (ObservedSource (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "InitiativePrefilter"
    [ testCase "recognized sources are exactly the closed list" do
        sourceKindFor (activityCoordinate "external/intercom") @?= Just IntercomConversation
        sourceKindFor (activityCoordinate "external/transcripts") @?= Just MeetingTranscript
        sourceKindFor (activityCoordinate "fixture/chat") @?= Just ChatFixture
        sourceKindFor (activityCoordinate "fixture/chat/other") @?= Nothing
        sourceKindFor (activityCoordinate "external/slack") @?= Nothing,
      testCase "an Intercom message describing a bug becomes a candidate with the subject prefixed" do
        settings <- configured ["intercom-conversation"]
        case disposition (Just settings) occurred received observer (envelope "external/intercom" intercomBody) of
          Evaluate _ candidate root -> do
            let facts = candidateFacts candidate
            excerptText facts.observed.excerpt @?= "Double charge\nDouble-clicking checkout charges the card twice"
            facts.observed.kind @?= IntercomConversation
            facts.evidence.subject.subjectId @?= activityCoordinate "conversation-1"
            facts.evidence.activity @?= activityCoordinate "activity-1"
            facts.evidence.occurredAt @?= claimed
            facts.evidence.digest @?= excerptDigestFor facts.observed.excerpt
            root.cutoff @?= UTCTime (fromGregorian 2026 11 4) 3700
          other -> assertFailure (show other),
      testCase "a transcript and a fixture chat line read their documented paths" do
        settings <- configured ["meeting-transcript", "chat-fixture"]
        case disposition (Just settings) occurred received observer (envelope "external/transcripts" (object ["transcript_text" .= long])) of
          Evaluate _ candidate _ -> excerptText (candidateFacts candidate).observed.excerpt @?= long
          other -> assertFailure (show other)
        case disposition (Just settings) occurred received observer (envelope "fixture/chat" (object ["text" .= long])) of
          Evaluate _ candidate _ -> (candidateFacts candidate).observed.kind @?= ChatFixture
          other -> assertFailure (show other),
      testCase "an oversized transcript is truncated, never refused" do
        settings <- configured ["meeting-transcript"]
        case disposition (Just settings) occurred received observer (envelope "external/transcripts" (object ["transcript_text" .= Text.replicate 9000 "x"])) of
          Evaluate _ candidate _ -> Text.length (excerptText (candidateFacts candidate).observed.excerpt) @?= 8192
          other -> assertFailure (show other),
      testCase "carriage returns and stray controls do not refuse a message" do
        settings <- configured ["chat-fixture"]
        case disposition (Just settings) occurred received observer (envelope "fixture/chat" (object ["text" .= ("first line\r\nsecond\a line of the report" :: Text)])) of
          Evaluate _ candidate _ -> excerptText (candidateFacts candidate).observed.excerpt @?= "first line\nsecond line of the report"
          other -> assertFailure (show other),
      testCase "agent-authored, unknown-source and textless envelopes are bounded skips" do
        settings <- configured ["chat-fixture"]
        let agentAuthored = envelopeBy (Actor {kind = AgentActor, id = activityCoordinate "agent_other", session = Nothing}) claimedText "fixture/chat" (object ["text" .= long])
        assertSkip (disposition (Just settings) occurred received observer agentAuthored) (skipEnvelope Initiative.AgentActor)
        assertSkip (disposition (Just settings) occurred received observer (envelope "external/slack" (object ["text" .= long]))) (skipEnvelope UnsupportedSource)
        assertSkip (disposition (Just settings) occurred received observer (envelope "fixture/chat" (object []))) (skipEnvelope ExcerptTooShort)
        assertSkip (disposition (Just settings) occurred received observer (envelope "fixture/chat" (object ["text" .= (42 :: Int)]))) (skipEnvelope ExcerptTooShort)
        assertSkip (disposition (Just settings) occurred received observer (envelope "fixture/chat" (object ["body" .= long]))) (skipEnvelope ExcerptTooShort),
      testCase "a source outside the allowance and a short excerpt are recorded with their subject" do
        settings <- configured ["chat-fixture"]
        assertSkip (disposition (Just settings) occurred received observer (envelope "external/intercom" intercomBody)) (skipObserved SourceNotPermitted)
        assertSkip (disposition (Just settings) occurred received observer (envelope "fixture/chat" (object ["text" .= ("too short" :: Text)]))) (skipObserved ExcerptTooShort),
      testCase "an agent without an allowance, or without settings, is not observing" do
        settings <- configured ["chat-fixture"]
        other <- either (assertFailure . Text.unpack) pure (mkAgentPrincipal "agent_other")
        assertSkip (disposition (Just settings) occurred received (VerifiedIdentity other) (envelope "fixture/chat" (object ["text" .= long]))) isNotObserving
        assertSkip (disposition Nothing occurred received observer (envelope "fixture/chat" (object ["text" .= long]))) isNotObserving,
      testCase "an unparseable occurrence claim takes the caller's instant" do
        let unparseable = envelopeBy customer "yesterday-ish" "fixture/chat" (object ["text" .= long])
        case observe occurred unparseable of
          Right observed -> observed.occurredAt @?= occurred
          Left reason -> assertFailure (show reason),
      testCase "the same inputs yield the same disposition and no input throws" do
        settings <- configured ["chat-fixture", "intercom-conversation", "meeting-transcript"]
        forM_ edgeEnvelopes \value -> do
          let first = disposition (Just settings) occurred received observer value
          first @?= disposition (Just settings) occurred received observer value
          void (evaluate (length (show first)))
    ]

skipEnvelope :: SkipReason -> Disposition -> Bool
skipEnvelope expected = \case
  SkipEnvelope _ reason -> reason == expected
  _ -> False

skipObserved :: SkipReason -> Disposition -> Bool
skipObserved expected = \case
  SkipObserved _ reason _ -> reason == expected
  _ -> False

isNotObserving :: Disposition -> Bool
isNotObserving = \case
  NotObserving -> True
  _ -> False

assertSkip :: Disposition -> (Disposition -> Bool) -> IO ()
assertSkip value check = assertBool (show value) (check value)

edgeEnvelopes :: [ActivityEnvelope]
edgeEnvelopes =
  [ envelope source payload
  | source <- ["fixture/chat", "external/intercom", "external/transcripts", "unknown", ""],
    payload <-
      [ object [],
        object ["text" .= ("" :: Text)],
        object ["text" .= Text.replicate 8193 "y"],
        object ["text" .= ("\a\b\ESC" :: Text)],
        object ["body" .= ("   " :: Text), "subject" .= (" " :: Text)],
        object ["transcript_text" .= ("\n\n\t" :: Text)],
        object ["text" .= ("日本語の説明がここにあります、とても長い説明です" :: Text)],
        toJSONNull
      ]
  ]
  where
    toJSONNull = encodeNull

encodeNull :: Value
encodeNull = either (error . show) id (eitherDecode "null")

configured :: [Text] -> IO InitiativeSettings
configured sources =
  either assertFailure pure (eitherDecode (encode document))
  where
    document =
      object
        [ "observers"
            .= [ object
                   [ "principal" .= ("agent_proposer" :: Text),
                     "sources" .= sources,
                     "minimumExcerptLength" .= (20 :: Int),
                     "evaluation" .= object ["limits" .= object ["ModelAttempts" .= (1 :: Int)], "cutoff" .= (3600 :: Int)],
                     "evaluationsPerWindow" .= (10 :: Int),
                     "proposalsPerWindow" .= (5 :: Int),
                     "notificationsPerWindow" .= (5 :: Int),
                     "window" .= (3600 :: Int),
                     "proposalExpiry" .= (86400 :: Int),
                     "rejectionSuppression" .= (604800 :: Int),
                     "notices" .= object ["kizashiRecipient" .= ("recipient_ops" :: Text)]
                   ]
               ]
        ]

observer :: AgentIdentity
observer = VerifiedIdentity (either (error . Text.unpack) id (mkAgentPrincipal "agent_proposer"))

occurred, received, claimed :: UTCTime
occurred = UTCTime (fromGregorian 2026 11 4) 90
received = UTCTime (fromGregorian 2026 11 4) 100
claimed = UTCTime (fromGregorian 2026 11 4) 61

long :: Text
long = "Double-clicking checkout charges the card twice on every attempt"

intercomBody :: Value
intercomBody = object ["subject" .= ("Double charge" :: Text), "body" .= ("Double-clicking checkout charges the card twice" :: Text)]

customer :: Actor
customer = Actor {kind = HumanActor, id = activityCoordinate "customer-1", session = Nothing}

claimedText :: Text
claimedText = "2026-11-04T00:01:01Z"

envelope :: Text -> Value -> ActivityEnvelope
envelope = envelopeBy customer claimedText

envelopeBy :: Actor -> Text -> Text -> Value -> ActivityEnvelope
envelopeBy actor occurredAt source payload =
  ActivityEnvelope
    { activityId = activityCoordinate "activity-1",
      occurredAt = activityCoordinate occurredAt,
      source = activityCoordinate source,
      actor,
      subject = Subject {kind = activityCoordinate "conversation", subjectId = activityCoordinate "conversation-1"},
      verb = activityCoordinate "message.created",
      payload,
      contextRefs = [],
      idempotencyKey = activityCoordinate "key-1"
    }
