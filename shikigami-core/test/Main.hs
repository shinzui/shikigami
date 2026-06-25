module Main (main) where

import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Network.HTTP.Types (hContentType, status200, status400, status404)
import Network.Wai (Application, pathInfo, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Shikigami.Api.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Api.Agent (Priority (Normal), RecipientFrom (SubjectOwner), SignalType (Reminder), Sink (..), StreamMatch (..))
import Shikigami.Sink
  ( AgentIdentity (..),
    KawaConfig (..),
    KizashiConfig (..),
    SinkContext (..),
    SinkOutcome (..),
    SinkResult (..),
  )
import Shikigami.Sink qualified as Sink
import Shikigami.Sink.KawaStub (stubKawaApplication)
import Shikigami.Sink.Wire (CreateSignalReq (..), SignalResponse (..))
import Shikigami.Trigger.Schedule (isDue, parseCron)
import Shikigami.Trigger.Stream (IncludeAgentActors (IncludeAgentActors), matchesStream, matchesStreamWith)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

main :: IO ()
main =
  defaultMain
    ( testGroup
        "shikigami"
        [ testGroup "Sink" [kizashiTests, kawaTests],
          testGroup "Trigger" [scheduleTests, streamTests]
        ]
    )

-- ── Trigger.Schedule ────────────────────────────────────────────────────────

atHour :: Int -> UTCTime
atHour h = UTCTime (fromGregorian 2026 6 20) (secondsToDiffTime (fromIntegral h * 3600))

scheduleTests :: TestTree
scheduleTests =
  testGroup
    "Schedule"
    [ testCase "every-minute cron is always due" $
        case parseCron "* * * * *" of
          Right c -> assertBool "due at any time" (isDue c (atHour 3))
          Left e -> assertBool ("parse failed: " <> show e) False,
      testCase "0 9 * * * is due at 09:00, not at 10:00" $
        case parseCron "0 9 * * *" of
          Right c -> do
            assertBool "due at 09:00" (isDue c (atHour 9))
            assertBool "not due at 10:00" (not (isDue c (atHour 10)))
          Left e -> assertBool ("parse failed: " <> show e) False,
      testCase "malformed cron fails to parse" $
        case parseCron "not a cron" of
          Left _ -> pure ()
          Right _ -> assertBool "expected parse failure" False
    ]

-- ── Trigger.Stream ──────────────────────────────────────────────────────────

envelopeWith :: Text -> Text -> Text -> Text -> ActivityEnvelope
envelopeWith actorKind verbV sourceV subjType =
  ActivityEnvelope
    { activityId = "act_seed",
      occurredAt = "2026-06-20T07:00:00Z",
      source = sourceV,
      actor = Actor {kind = actorKind, id = "someone", session = Nothing},
      subject = Subject {subjectType = subjType, subjectId = "i-1"},
      verb = verbV,
      payload = object [],
      contextRefs = [],
      idempotencyKey = "act_seed"
    }

matchAll :: StreamMatch
matchAll = StreamMatch {verb = Just "intention.declared", source = Nothing, subjectType = Just "intention", verbs = []}

streamTests :: TestTree
streamTests =
  testGroup
    "Stream"
    [ testCase "matches on verb + subjectType (human actor)" $
        assertBool "should match" (matchesStream matchAll (envelopeWith "human" "intention.declared" "shinzui/rei" "intention")),
      testCase "absent predicate is ignored (source = Nothing)" $
        assertBool "should match regardless of source" (matchesStream matchAll (envelopeWith "human" "intention.declared" "any/source" "intention")),
      testCase "non-match on differing verb" $
        assertBool "should not match" (not (matchesStream matchAll (envelopeWith "human" "ticket.received" "shinzui/rei" "intention"))),
      testCase "feedback guard: actor.kind=agent excluded by default" $
        assertBool "agent actor excluded" (not (matchesStream matchAll (envelopeWith "agent" "intention.declared" "shinzui/rei" "intention"))),
      testCase "opt-in includes agent actors" $
        assertBool "agent actor included with opt-in" (matchesStreamWith IncludeAgentActors matchAll (envelopeWith "agent" "intention.declared" "shinzui/rei" "intention"))
    ]

-- | A stub kizashi server: records each CreateSignalReq and returns a fixed response.
stubKizashiApp :: IORef [CreateSignalReq] -> Application
stubKizashiApp ref req respond =
  case (requestMethod req, pathInfo req) of
    ("POST", ["v1", "signals"]) -> do
      body <- strictRequestBody req
      case eitherDecode body of
        Right csr -> do
          modifyIORef' ref (csr :)
          respond (responseLBS status200 [(hContentType, "application/json")] (encode (SignalResponse "sig_stub" "active")))
        Left e -> respond (responseLBS status400 [] (LBS8.pack e))
    _ -> respond (responseLBS status404 [] "not found")

sampleKizashiSink :: Sink
sampleKizashiSink =
  KizashiSignal
    { source = "shinzui/shikigami",
      signalType = Reminder,
      priority = Normal,
      importance = 50,
      recipientFrom = SubjectOwner,
      defaultRecipient = Just "recipient_x",
      intentTemplate = "triage this",
      extraContextTags = ["verb:x"]
    }

ctxFor :: AgentIdentity -> KizashiConfig -> KawaConfig -> SinkContext
ctxFor ident kz kw =
  SinkContext
    { sinkCtxIdentity = ident,
      sinkCtxRunId = "run-1",
      sinkCtxOrdinal = 0,
      sinkCtxKizashi = kz,
      sinkCtxKawa = kw,
      sinkCtxOccurredAt = Nothing
    }

dummyKawa :: KawaConfig
dummyKawa = KawaConfig {kawaBaseUrl = "http://localhost:1", kawaSourceSegment = "shinzui/shikigami"}

kizashiTests :: TestTree
kizashiTests =
  testGroup
    "KizashiSignal"
    [ testCase "allow-listed: POSTs a CreateSignalReq, outcome Delivered" $ do
        ref <- newIORef []
        testWithApplication (pure (stubKizashiApp ref)) $ \port -> do
          let kz = KizashiConfig {kizashiBaseUrl = baseUrl port, kizashiDefaultRecipient = "recipient_default"}
              ctx = ctxFor (AgentIdentity "heartbeat") kz dummyKawa
          r <- Sink.dispatch ctx sampleKizashiSink sampleOutput
          sinkResultOutcome r @?= Delivered "sig_stub"
          reqs <- readIORef ref
          assertEqual "one signal recorded" 1 (length reqs)
          case reqs of
            (CreateSignalReq {source = s} : _) -> s @?= "shinzui/shikigami"
            [] -> assertBool "expected a recorded signal" False,
      testCase "denied: skipped and recorded, no POST" $ do
        ref <- newIORef []
        testWithApplication (pure (stubKizashiApp ref)) $ \port -> do
          let kz = KizashiConfig {kizashiBaseUrl = baseUrl port, kizashiDefaultRecipient = "recipient_default"}
              ctx = ctxFor (AgentIdentity "intruder") kz dummyKawa
          r <- Sink.dispatch ctx sampleKizashiSink sampleOutput
          case sinkResultOutcome r of
            DeniedOutcome _ -> pure ()
            other -> assertBool ("expected DeniedOutcome, got " <> show other) False
          reqs <- readIORef ref
          assertEqual "no signal recorded for denied agent" 0 (length reqs)
    ]

kawaTests :: TestTree
kawaTests =
  testGroup
    "KawaDigest"
    [ testCase "dispatch builds + posts envelope; idempotent on (source, source_event_id)" $ do
        store <- newIORef (Map.empty :: Map (Text, Text) Text)
        testWithApplication (pure (stubKawaApplication store Nothing)) $ \port -> do
          let kw = KawaConfig {kawaBaseUrl = baseUrl port, kawaSourceSegment = "shinzui/shikigami"}
              dummyKz = KizashiConfig {kizashiBaseUrl = "http://localhost:1", kizashiDefaultRecipient = "r"}
              ctx = ctxFor (AgentIdentity "heartbeat") dummyKz kw
              sink = KawaDigest {subjectType = "heartbeat", verb = "heartbeat.tick"}
          r1 <- Sink.dispatch ctx sink sampleOutput
          r2 <- Sink.dispatch ctx sink sampleOutput
          case (sinkResultOutcome r1, sinkResultOutcome r2) of
            (Delivered a1, Delivered a2) -> do
              assertBool "activity id non-empty" (not (Text.null a1))
              assertEqual "same activity id on retry (deduplicated)" a1 a2
            other -> assertBool ("expected two Delivered, got " <> show other) False
          m <- readIORef store
          assertEqual "exactly one stored (source, source_event_id)" 1 (Map.size m)
    ]

sampleOutput :: Data.Aeson.Value
sampleOutput = object ["summary" .= ("heartbeat ok" :: Text), "activity_ref" .= ("activity://act_seed" :: Text)]

baseUrl :: Int -> Text
baseUrl port = "http://localhost:" <> Text.pack (show port)
