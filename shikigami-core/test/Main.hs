module Main (main) where

import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Network.HTTP.Types (hContentType, status200, status204, status400, status404)
import Network.Wai (Application, Request, Response, ResponseReceived, pathInfo, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Agent.Decl (Priority (Normal), RecipientFrom (SubjectOwner), SignalType (Reminder), Sink (..), StreamMatch (..))
import Shikigami.AgentWorkflowSpec qualified as AgentWorkflowSpec
import Shikigami.AppConfigSpec qualified as AppConfigSpec
import Shikigami.BehaviorInputSpec qualified as BehaviorInputSpec
import Shikigami.BehaviorProviderSpec qualified as BehaviorProviderSpec
import Shikigami.DelegateContextSpec qualified as DelegateContextSpec
import Shikigami.Fixture.KawaStub (kawaDoorwayApplication)
import Shikigami.FlowLifecycleSpec qualified as FlowLifecycleSpec
import Shikigami.Integration.Danwa (AddressedMessage (..), addressedMessageEventType)
import Shikigami.Log qualified as Log
import Shikigami.LogSpec qualified as LogSpec
import Shikigami.PackageArchitectureSpec qualified as PackageArchitectureSpec
import Shikigami.Sink
  ( AgentIdentity (..),
    DanwaConfig (..),
    DanwaTarget (..),
    GrantSource (StaticGrants),
    KawaConfig (..),
    KizashiConfig (..),
    SinkContext (..),
    SinkOutcome (..),
    SinkResult (..),
    defaultGrantTable,
  )
import Shikigami.Sink qualified as Sink
import Shikigami.Sink.Wire (CreateSignalReq (..), SignalResponse (..))
import Shikigami.SinkHonestySpec qualified as SinkHonestySpec
import Shikigami.SpikeWorkflowSpec qualified as SpikeWorkflowSpec
import Shikigami.Trigger.Schedule (isDue, nextDue, parseCron)
import Shikigami.Trigger.Stream (IncludeAgentActors (IncludeAgentActors), matchesStream, matchesStreamWith)
import Shikigami.WireCompatSpec qualified as WireCompatSpec
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

main :: IO ()
main =
  defaultMain
    ( testGroup
        "shikigami"
        [ testGroup "Sink" [kizashiTests, kawaTests, danwaTests],
          testGroup "Trigger" [scheduleTests, streamTests, danwaIntegrationTests],
          AppConfigSpec.tests,
          BehaviorInputSpec.tests,
          BehaviorProviderSpec.tests,
          DelegateContextSpec.tests,
          LogSpec.tests,
          PackageArchitectureSpec.tests,
          SinkHonestySpec.tests,
          FlowLifecycleSpec.tests,
          AgentWorkflowSpec.tests,
          SpikeWorkflowSpec.tests,
          WireCompatSpec.tests
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
          Right _ -> assertBool "expected parse failure" False,
      testCase "nextDue is strictly after the supplied minute" $
        case parseCron "* * * * *" of
          Right c -> nextDue c (atHour 3) @?= Just (UTCTime (fromGregorian 2026 6 20) (secondsToDiffTime (3 * 3600 + 60)))
          Left e -> assertBool ("parse failed: " <> show e) False
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

danwaIntegrationTests :: TestTree
danwaIntegrationTests =
  testGroup
    "DanwaIntegration"
    [ testCase "decodes the public addressed-message payload" do
        let payload =
              """
              {"conversationId":"conv_public_1","messageId":"msg_public_1","parentMessageId":null,
               "author":"part_human_test","content":"please help","agentParticipantId":"part_agent_test",
               "embellishmentId":"emb_public_1","mentionedBy":"part_human_test",
               "occurredAt":"2026-06-27T00:00:00Z"}
              """
        case eitherDecode @AddressedMessage payload of
          Left err -> assertBool ("decode failed: " <> err) False
          Right msg ->
            msg
              @?= AddressedMessage
                { conversationId = "conv_public_1",
                  messageId = "msg_public_1",
                  parentMessageId = Nothing,
                  author = "part_human_test",
                  content = "please help",
                  agentParticipantId = "part_agent_test",
                  embellishmentId = "emb_public_1",
                  mentionedBy = "part_human_test",
                  occurredAt = UTCTime (fromGregorian 2026 6 27) 0
                },
      testCase "uses Danwa's public integration event type" $
        addressedMessageEventType @?= "danwa.message-addressed-to-agent"
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
    { identity = ident,
      runId = "run-1",
      ordinal = 0,
      kizashi = kz,
      kawa = kw,
      danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_test"},
      rei = Sink.ReiConfig {baseUrl = Nothing},
      danwaTarget = Nothing,
      recipientOverride = Nothing,
      occurredAt = Nothing,
      logger = Log.silentLogger,
      grants = StaticGrants defaultGrantTable
    }

dummyKawa :: KawaConfig
dummyKawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = "shinzui/shikigami"}

dummyKizashi :: KizashiConfig
dummyKizashi = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "recipient_default"}

ctxForDanwa :: AgentIdentity -> DanwaConfig -> Maybe DanwaTarget -> SinkContext
ctxForDanwa ident danwa target =
  (ctxFor ident dummyKizashi dummyKawa)
    { danwa = danwa,
      danwaTarget = target
    }

kizashiTests :: TestTree
kizashiTests =
  testGroup
    "KizashiSignal"
    [ testCase "allow-listed: POSTs a CreateSignalReq, outcome Delivered" $ do
        ref <- newIORef []
        testWithApplication (pure (stubKizashiApp ref)) $ \port -> do
          let kz = KizashiConfig {baseUrl = testBaseUrl port, defaultRecipient = "recipient_default"}
              ctx = ctxFor (AgentIdentity "heartbeat") kz dummyKawa
          r <- Sink.dispatch ctx sampleKizashiSink sampleOutput
          outcome r @?= Delivered "sig_stub"
          reqs <- readIORef ref
          assertEqual "one signal recorded" 1 (length reqs)
          case reqs of
            (CreateSignalReq {source = s} : _) -> s @?= "shinzui/shikigami"
            [] -> assertBool "expected a recorded signal" False,
      testCase "denied: skipped and recorded, no POST" $ do
        ref <- newIORef []
        testWithApplication (pure (stubKizashiApp ref)) $ \port -> do
          let kz = KizashiConfig {baseUrl = testBaseUrl port, defaultRecipient = "recipient_default"}
              ctx = ctxFor (AgentIdentity "intruder") kz dummyKawa
          r <- Sink.dispatch ctx sampleKizashiSink sampleOutput
          case outcome r of
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
        testWithApplication (pure (kawaDoorwayApplication store)) $ \port -> do
          let kw = KawaConfig {baseUrl = testBaseUrl port, sourceSegment = "shinzui/shikigami"}
              dummyKz = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "r"}
              ctx = ctxFor (AgentIdentity "heartbeat") dummyKz kw
              sink = KawaDigest {subjectType = "heartbeat", verb = "heartbeat.tick"}
          r1 <- Sink.dispatch ctx sink sampleOutput
          r2 <- Sink.dispatch ctx sink sampleOutput
          case (outcome r1, outcome r2) of
            (Delivered a1, Delivered a2) -> do
              assertBool "activity id non-empty" (not (Text.null a1))
              assertEqual "same activity id on retry (deduplicated)" a1 a2
            other -> assertBool ("expected two Delivered, got " <> show other) False
          m <- readIORef store
          assertEqual "exactly one stored (source, source_event_id)" 1 (Map.size m)
    ]

-- | A small danwa-compatible HTTP stub for the sink client. It records message request
-- bodies and returns fixed TypeID-shaped ids.
stubDanwaApp :: IORef [Value] -> Application
stubDanwaApp ref req respond =
  case (requestMethod req, pathInfo req) of
    ("POST", ["conversations"]) ->
      respond
        ( responseLBS
            status200
            [(hContentType, "application/json")]
            ( encode
                ( object
                    [ "conversationId" .= ("conv_stub" :: Text),
                      "status" .= ("active" :: Text),
                      "kind" .= ("thread" :: Text),
                      "startedBy" .= ("part_agent_test" :: Text),
                      "parentConversationId" .= ("" :: Text)
                    ]
                )
            )
        )
    ("POST", ["conversations", "conv_stub", "participants"]) ->
      respond (responseLBS status204 [] "")
    ("POST", ["conversations", "conv_stub", "messages"]) ->
      respondMessage ref req "conv_stub" "msg_stub" respond
    ("POST", ["conversations", "conv_target", "messages", "msg_parent", "replies"]) ->
      respondMessage ref req "conv_target" "msg_reply" respond
    _ -> respond (responseLBS status404 [] "not found")

respondMessage :: IORef [Value] -> Request -> Text -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
respondMessage ref req cid mid respond = do
  body <- strictRequestBody req
  case eitherDecode body of
    Right value -> do
      modifyIORef' ref (value :)
      respond
        ( responseLBS
            status200
            [(hContentType, "application/json")]
            ( encode
                ( object
                    [ "messageId" .= mid,
                      "conversationId" .= cid,
                      "author" .= ("part_agent_test" :: Text),
                      "content" .= ("reply text" :: Text),
                      "postedAt" .= ("2026-06-27T00:00:00Z" :: Text)
                    ]
                )
            )
        )
    Left err -> respond (responseLBS status400 [] (LBS8.pack err))

danwaTests :: TestTree
danwaTests =
  testGroup
    "DanwaConversation"
    [ -- A reply ignores the declared topic on purpose: the thread already has
      -- its context, and re-announcing it on every message would be noise.
      testCase "targeted reply posts through danwa and returns Delivered msg id" do
        ref <- newIORef []
        testWithApplication (pure (stubDanwaApp ref)) \port -> do
          let cfg = DanwaConfig {baseUrl = testBaseUrl port, agentParticipant = "part_agent_test"}
              target = Just DanwaTarget {conversationId = "conv_target", parentMessageId = Just "msg_parent"}
              ctx = ctxForDanwa (AgentIdentity "heartbeat") cfg target
              sink = DanwaConversation {topic = "support"}
          r <- Sink.dispatch ctx sink (object ["reply" .= ("reply text" :: Text)])
          outcome r @?= Delivered "msg_reply"
          reqs <- readIORef ref
          assertEqual "one danwa message recorded" 1 (length reqs)
          postedContent reqs @?= Just "reply text",
      -- danwa has no conversation topic to set, so a declared topic becomes the
      -- first line of the opening message. Before this, it was accepted and
      -- discarded.
      testCase "untargeted sink starts a conversation and opens with the declared topic" do
        ref <- newIORef []
        testWithApplication (pure (stubDanwaApp ref)) \port -> do
          let cfg = DanwaConfig {baseUrl = testBaseUrl port, agentParticipant = "part_agent_test"}
              ctx = ctxForDanwa (AgentIdentity "heartbeat") cfg Nothing
              sink = DanwaConversation {topic = "support"}
          r <- Sink.dispatch ctx sink (object ["summary" .= ("fresh thread text" :: Text)])
          outcome r @?= Delivered "msg_stub"
          reqs <- readIORef ref
          assertEqual "one danwa message recorded" 1 (length reqs)
          postedContent reqs @?= Just "[support]\nfresh thread text",
      testCase "a declaration with no topic opens exactly as it did before" do
        ref <- newIORef []
        testWithApplication (pure (stubDanwaApp ref)) \port -> do
          let cfg = DanwaConfig {baseUrl = testBaseUrl port, agentParticipant = "part_agent_test"}
              ctx = ctxForDanwa (AgentIdentity "heartbeat") cfg Nothing
              sink = DanwaConversation {topic = ""}
          _ <- Sink.dispatch ctx sink (object ["summary" .= ("fresh thread text" :: Text)])
          reqs <- readIORef ref
          postedContent reqs @?= Just "fresh thread text"
    ]

-- | The @content@ of the single message the danwa stub recorded.
postedContent :: [Value] -> Maybe Text
postedContent = \case
  [Object o] -> case KeyMap.lookup "content" o of
    Just (String s) -> Just s
    _ -> Nothing
  _ -> Nothing

sampleOutput :: Data.Aeson.Value
sampleOutput = object ["summary" .= ("heartbeat ok" :: Text), "activity_ref" .= ("activity://act_seed" :: Text)]

testBaseUrl :: Int -> Text
testBaseUrl port = "http://localhost:" <> Text.pack (show port)
