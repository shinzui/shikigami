-- | Dispatch of the Kikan outputs against local HTTP stubs: Kizashi signals,
-- Kawa digests, Danwa conversations and their trace headers (moved from the
-- kernel's suite with the adapters, plan 135 M3).
module Kikan.Shikigami.Binding.OutputDispatchSpec (tests) where

import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Kikan.Shikigami.Binding.Fixture.KawaStub (kawaDoorwayApplication)
import Kikan.Shikigami.Binding.Fixture.OutboxDispatch (DispatchContext, deliveryFor, dispatchContext, dispatchOutput, withIdentity, withServices, withTraceHeaders)
import Kikan.Shikigami.Binding.Fixture.SinkHttp (testSinkHttpFor)
import Kikan.Shikigami.Binding.Output (KikanServices (..))
import Kikan.Shikigami.Binding.Output.Config (DanwaConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Kikan.Shikigami.Binding.Output.Kawa (buildEnvelope)
import Kikan.Shikigami.Binding.Output.Wire (CreateSignalReq (..), SignalResponse (..))
import Kikan.Shikigami.Binding.Outputs
import Network.HTTP.Types (hContentType, status200, status204, status400, status404)
import Network.HTTP.Types.Header (Header)
import Network.Wai (Application, Request, Response, ResponseReceived, pathInfo, requestHeaders, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), ContextRef (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl (StreamMatch (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Output (OutputDecl (..))
import Shikigami.Sink
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "Output dispatch" [kizashiTests, kawaTests, danwaTests, traceHeaderTests]

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

sampleKizashiSink :: OutputDecl
sampleKizashiSink =
  ( kizashiSignalOutput
      KizashiSignalOutput
        { source = activityCoordinate ("shinzui/shikigami"),
          signalType = Reminder,
          priority = Normal,
          importance = either (error . show) id (parseSignalImportance (50)),
          recipientFrom = SubjectOwner,
          defaultRecipient = fmap declarationCoordinate (Just "recipient_x"),
          intentTemplate = "triage this",
          extraContextTags = ["verb:x"],
          recipient = Nothing
        }
  )

ctxFor :: AgentIdentity -> KizashiConfig -> KawaConfig -> DispatchContext
ctxFor ident kz kw = withIdentity ident (withServices (\services -> services {kizashi = kz, kawa = kw}) dispatchContext)

dispatchSink :: DispatchContext -> OutputDecl -> Value -> IO SinkResult
dispatchSink = dispatchOutput

dummyKawa :: KawaConfig
dummyKawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = (activityCoordinate "shinzui/shikigami")}

dummyKizashi :: KizashiConfig
dummyKizashi = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = (declarationCoordinate "recipient_default")}

ctxForDanwa :: AgentIdentity -> DanwaConfig -> IO DispatchContext
ctxForDanwa ident danwa = do
  sinkHttp <- testSinkHttpFor danwa
  pure (withServices (\services -> services {danwa, http = sinkHttp}) (ctxFor ident dummyKizashi dummyKawa))

-- | A Danwa sink, posted into @target@ when there is one.
danwaDispatch :: DispatchContext -> Maybe DanwaTarget -> OutputDecl -> Value -> IO SinkResult
danwaDispatch ctx target sink = dispatchOutput ctx (maybe id inThread target (sink))

kizashiTests :: TestTree
kizashiTests =
  testGroup
    "KizashiSignal"
    [ testCase "allow-listed: POSTs a CreateSignalReq, outcome Delivered" $ do
        ref <- newIORef []
        testWithApplication (pure (stubKizashiApp ref)) $ \port -> do
          let kz = KizashiConfig {baseUrl = testBaseUrl port, defaultRecipient = (declarationCoordinate "recipient_default")}
              ctx = ctxFor (compatibilityIdentity (fixtureAgentName "heartbeat")) kz dummyKawa
          r <- dispatchSink ctx sampleKizashiSink sampleOutput
          (.outcome) r @?= Delivered (declarationCoordinate "sig_stub")
          reqs <- readIORef ref
          assertEqual "one signal recorded" 1 (length reqs)
          case reqs of
            (CreateSignalReq {source = s} : _) -> s @?= "shinzui/shikigami"
            [] -> assertBool "expected a recorded signal" False,
      testCase "denied: skipped and recorded, no POST" $ do
        ref <- newIORef []
        testWithApplication (pure (stubKizashiApp ref)) $ \port -> do
          let kz = KizashiConfig {baseUrl = testBaseUrl port, defaultRecipient = (declarationCoordinate "recipient_default")}
              ctx = ctxFor (compatibilityIdentity (fixtureAgentName "intruder")) kz dummyKawa
          r <- dispatchSink ctx sampleKizashiSink sampleOutput
          case (.outcome) r of
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
          let kw = KawaConfig {baseUrl = testBaseUrl port, sourceSegment = (activityCoordinate "shinzui/shikigami")}
              dummyKz = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = (declarationCoordinate "r")}
              ctx = ctxFor (compatibilityIdentity (fixtureAgentName "heartbeat")) dummyKz kw
              sink = (kawaDigestOutput KawaDigestOutput {subjectType = activityCoordinate ("heartbeat"), verb = activityCoordinate ("heartbeat.tick")})
          r1 <- dispatchSink ctx sink sampleOutput
          r2 <- dispatchSink ctx sink sampleOutput
          case ((.outcome) r1, (.outcome) r2) of
            (Delivered a1, Delivered a2) -> do
              assertBool "activity id non-empty" (not (Text.null (declarationCoordinateText a1)))
              assertEqual "same activity id on retry (deduplicated)" a1 a2
            other -> assertBool ("expected two Delivered, got " <> show other) False
          m <- readIORef store
          assertEqual "exactly one stored (source, source_event_id)" 1 (Map.size m),
      testCase "context refs are bounded to closed schemes and deduplicated before ingest" do
        let ctx = ctxFor (compatibilityIdentity (fixtureAgentName "heartbeat")) dummyKizashi dummyKawa
            sink = KawaDigestOutput {subjectType = activityCoordinate ("practice-review"), verb = activityCoordinate ("practice-review.completed")}
            output =
              object
                [ "context_refs"
                    .= [ object ["scheme" .= ("mori://" :: Text), "ref" .= ("shinzui/example" :: Text)],
                         object ["scheme" .= ("mori://" :: Text), "ref" .= ("shinzui/example" :: Text)],
                         object ["scheme" .= ("activity://" :: Text), "ref" .= ("practice-review/review-1" :: Text)]
                       ]
                ]
        buildEnvelope (deliveryFor ctx (kawaDigestOutput sink) output) sink >>= \case
          Left problem -> assertFailure (show problem)
          Right ActivityEnvelope {contextRefs} ->
            contextRefs
              @?= [ ContextRef {scheme = MoriContext, ref = either (error . show) id (parseContextReference ("shinzui/example"))},
                    ContextRef {scheme = ActivityContext, ref = either (error . show) id (parseContextReference ("practice-review/review-1"))}
                  ],
      testCase "malformed context refs fail permanently before HTTP" do
        store <- newIORef (Map.empty :: Map (Text, Text) Text)
        testWithApplication (pure (kawaDoorwayApplication store)) $ \port -> do
          let kw = KawaConfig {baseUrl = testBaseUrl port, sourceSegment = (activityCoordinate "shinzui/shikigami")}
              ctx = ctxFor (compatibilityIdentity (fixtureAgentName "heartbeat")) dummyKizashi kw
              sink = (kawaDigestOutput KawaDigestOutput {subjectType = activityCoordinate ("practice-review"), verb = activityCoordinate ("practice-review.completed")})
              output = object ["context_refs" .= [object ["scheme" .= ("https://" :: Text), "ref" .= ("example.invalid" :: Text)]]]
          result <- dispatchSink ctx sink output
          case (.outcome) result of
            PermanentFailure detail -> assertBool "failure does not name the bad scheme" ("unknown context_refs scheme" `Text.isInfixOf` detail)
            other -> assertFailure ("malformed context refs were not permanent: " <> show other)
          stored <- readIORef store
          assertEqual "malformed refs made an HTTP request" 0 (Map.size stored)
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
          let cfg = DanwaConfig {baseUrl = testBaseUrl port, agentParticipant = (declarationCoordinate "part_agent_test")}
              target = Just DanwaTarget {conversationId = (declarationCoordinate "conv_target"), parentMessageId = Just (declarationCoordinate "msg_parent")}
              sink = (danwaConversationOutput DanwaConversationOutput {topic = "support", thread = Nothing})
          ctx <- ctxForDanwa (compatibilityIdentity (fixtureAgentName "heartbeat")) cfg
          r <- danwaDispatch ctx target sink (object ["reply" .= ("reply text" :: Text)])
          (.outcome) r @?= Delivered (declarationCoordinate "msg_reply")
          reqs <- readIORef ref
          assertEqual "one danwa message recorded" 1 (length reqs)
          postedContent reqs @?= Just "reply text",
      -- danwa has no conversation topic to set, so a declared topic becomes the
      -- first line of the opening message. Before this, it was accepted and
      -- discarded.
      testCase "untargeted sink starts a conversation and opens with the declared topic" do
        ref <- newIORef []
        testWithApplication (pure (stubDanwaApp ref)) \port -> do
          let cfg = DanwaConfig {baseUrl = testBaseUrl port, agentParticipant = (declarationCoordinate "part_agent_test")}
              sink = (danwaConversationOutput DanwaConversationOutput {topic = "support", thread = Nothing})
          ctx <- ctxForDanwa (compatibilityIdentity (fixtureAgentName "heartbeat")) cfg
          r <- danwaDispatch ctx Nothing sink (object ["summary" .= ("fresh thread text" :: Text)])
          (.outcome) r @?= Delivered (declarationCoordinate "msg_stub")
          reqs <- readIORef ref
          assertEqual "one danwa message recorded" 1 (length reqs)
          postedContent reqs @?= Just "[support]\nfresh thread text",
      testCase "a declaration with no topic is denied before opening an unaddressable thread" do
        ref <- newIORef []
        testWithApplication (pure (stubDanwaApp ref)) \port -> do
          let cfg = DanwaConfig {baseUrl = testBaseUrl port, agentParticipant = (declarationCoordinate "part_agent_test")}
              sink = (danwaConversationOutput DanwaConversationOutput {topic = "", thread = Nothing})
          ctx <- ctxForDanwa (compatibilityIdentity (fixtureAgentName "heartbeat")) cfg
          result <- danwaDispatch ctx Nothing sink (object ["summary" .= ("fresh thread text" :: Text)])
          case (.outcome) result of
            AuthorizationFailed reason -> assertBool "the missing exact target is explicit" ("invalid coordinates" `Text.isInfixOf` reason)
            other -> assertFailure ("expected fail-closed authorization, got " <> show other)
          reqs <- readIORef ref
          reqs @?= []
    ]

traceHeaderTests :: TestTree
traceHeaderTests =
  testGroup
    "traceparent"
    [ testCase "kawa receives only the generated W3C trace headers" do
        headers <- newIORef []
        store <- newIORef (Map.empty :: Map (Text, Text) Text)
        testWithApplication (pure (captureHeaders headers (kawaDoorwayApplication store))) \port -> do
          let kw = KawaConfig {baseUrl = testBaseUrl port, sourceSegment = (activityCoordinate "shinzui/shikigami")}
              ctx = withTraceHeaders sampleTraceHeaders (ctxFor (compatibilityIdentity (fixtureAgentName "heartbeat")) dummyKizashi kw)
              sink = (kawaDigestOutput KawaDigestOutput {subjectType = activityCoordinate ("heartbeat"), verb = activityCoordinate ("heartbeat.tick")})
          _ <- dispatchSink ctx sink sampleOutput
          assertCapturedTraceHeaders headers,
      testCase "kizashi receives only the generated W3C trace headers" do
        headers <- newIORef []
        signals <- newIORef []
        testWithApplication (pure (captureHeaders headers (stubKizashiApp signals))) \port -> do
          let kz = KizashiConfig {baseUrl = testBaseUrl port, defaultRecipient = (declarationCoordinate "recipient_default")}
              ctx = withTraceHeaders sampleTraceHeaders (ctxFor (compatibilityIdentity (fixtureAgentName "heartbeat")) kz dummyKawa)
          _ <- dispatchSink ctx sampleKizashiSink sampleOutput
          assertCapturedTraceHeaders headers,
      testCase "rei receives only the generated W3C trace headers" do
        headers <- newIORef []
        testWithApplication (pure (captureHeaders headers acceptingReiApp)) \port -> do
          let ctx =
                withTraceHeaders sampleTraceHeaders (withServices (\services -> services {rei = ReiConfig {baseUrl = Just (testBaseUrl port)}}) (ctxFor (compatibilityIdentity (fixtureAgentName "heartbeat")) dummyKizashi dummyKawa))
              sink = (reiActionOutput ReiActionOutput {intentionId = declarationCoordinate ("int_trace"), note = "trace this action"})
          _ <- dispatchSink ctx sink sampleOutput
          assertCapturedTraceHeaders headers,
      testCase "danwa receives only the generated W3C trace headers" do
        headers <- newIORef []
        messages <- newIORef []
        testWithApplication (pure (captureHeaders headers (stubDanwaApp messages))) \port -> do
          let cfg = DanwaConfig {baseUrl = testBaseUrl port, agentParticipant = (declarationCoordinate "part_agent_test")}
              target = Just DanwaTarget {conversationId = (declarationCoordinate "conv_target"), parentMessageId = Just (declarationCoordinate "msg_parent")}
              sink = (danwaConversationOutput DanwaConversationOutput {topic = "support", thread = Nothing})
          baseCtx <- ctxForDanwa (compatibilityIdentity (fixtureAgentName "heartbeat")) cfg
          _ <- danwaDispatch (withTraceHeaders sampleTraceHeaders baseCtx) target sink sampleOutput
          assertCapturedTraceHeaders headers
    ]

sampleTraceHeaders :: [Header]
sampleTraceHeaders =
  [ ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"),
    ("tracestate", "shikigami=test")
  ]

captureHeaders :: IORef [[Header]] -> Application -> Application
captureHeaders headers app request respond = do
  modifyIORef' headers (requestHeaders request :)
  app request respond

assertCapturedTraceHeaders :: IORef [[Header]] -> IO ()
assertCapturedTraceHeaders headers = do
  requests <- readIORef headers
  assertBool "the sink issued at least one HTTP request" (not (null requests))
  mapM_ assertOne requests
  where
    assertOne requestHeaders' = do
      lookup "traceparent" requestHeaders' @?= lookup "traceparent" sampleTraceHeaders
      lookup "tracestate" requestHeaders' @?= lookup "tracestate" sampleTraceHeaders

acceptingReiApp :: Application
acceptingReiApp request respond =
  case (requestMethod request, pathInfo request) of
    ("POST", ["v1", "agent-actions"]) -> respond (responseLBS status204 [] "")
    _ -> respond (responseLBS status404 [] "not found")

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

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName
