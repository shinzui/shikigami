module Main (main) where

import Control.Lens ((&), (.~))
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
import Network.HTTP.Types (hContentType, status200, status204, status400, status404)
import Network.HTTP.Types.Header (Header)
import Network.Wai (Application, Request, Response, ResponseReceived, pathInfo, requestHeaders, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), ContextRef (..), Subject (..))
import Shikigami.Agent.Decl (Priority (Normal), RecipientFrom (SubjectOwner), SignalType (Reminder), Sink (..), StreamMatch (..))
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.AgentLoaderSpec qualified as AgentLoaderSpec
import Shikigami.AppConfigSpec qualified as AppConfigSpec
import Shikigami.ApprovalNotificationSpec qualified as ApprovalNotificationSpec
import Shikigami.AttestationContractsSpec qualified as AttestationContractsSpec
import Shikigami.BehaviorInputSpec qualified as BehaviorInputSpec
import Shikigami.BehaviorProviderSpec qualified as BehaviorProviderSpec
import Shikigami.BehaviorRetrySpec qualified as BehaviorRetrySpec
import Shikigami.BehaviorToolSpec qualified as BehaviorToolSpec
import Shikigami.CapabilityOverlaySpec qualified as CapabilityOverlaySpec
import Shikigami.CapabilityProviderSpec qualified as CapabilityProviderSpec
import Shikigami.DecisionContractSpec qualified as DecisionContractSpec
import Shikigami.DecisionModelCatalogSpec qualified as DecisionModelCatalogSpec
import Shikigami.DecisionRunnerSpec qualified as DecisionRunnerSpec
import Shikigami.DelegateContextSpec qualified as DelegateContextSpec
import Shikigami.DelegationBatchSpec qualified as DelegationBatchSpec
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.DirectorySpec qualified as DirectorySpec
import Shikigami.EnqueueHardeningSpec qualified as EnqueueHardeningSpec
import Shikigami.ExecutionPolicySpec qualified as ExecutionPolicySpec
import Shikigami.ExecutionPositionSpec qualified as ExecutionPositionSpec
import Shikigami.ExecutionResourcesSpec qualified as ExecutionResourcesSpec
import Shikigami.ExecutionSelectionSpec qualified as ExecutionSelectionSpec
import Shikigami.Fixture.KawaStub (kawaDoorwayApplication)
import Shikigami.Fixture.SinkHttp (testSinkHttp, testSinkHttpFor)
import Shikigami.Integration.Danwa (AddressedMessage (..), addressedMessageEventType)
import Shikigami.KanmonClientSpec qualified as KanmonClientSpec
import Shikigami.KeiroSpecificationSpec qualified as KeiroSpecificationSpec
import Shikigami.Log qualified as Log
import Shikigami.LogSpec qualified as LogSpec
import Shikigami.ObjectiveSpec qualified as ObjectiveSpec
import Shikigami.PackageArchitectureSpec qualified as PackageArchitectureSpec
import Shikigami.PracticeReviewEvidenceSpec qualified as PracticeReviewEvidenceSpec
import Shikigami.PracticeReviewSpec qualified as PracticeReviewSpec
import Shikigami.RouterCatalogSpec qualified as RouterCatalogSpec
import Shikigami.RouterDecisionSpec qualified as RouterDecisionSpec
import Shikigami.RouterDeclarationSpec qualified as RouterDeclarationSpec
import Shikigami.Sink
  ( AgentIdentity,
    DanwaConfig (..),
    DanwaTarget (..),
    GrantSource (StaticGrants),
    KanmonConfig (..),
    KawaConfig (..),
    KizashiConfig (..),
    SinkContext (..),
    SinkOutcome (..),
    SinkResult (..),
    defaultGrantTable,
  )
import Shikigami.Sink qualified as Sink
import Shikigami.Sink.KawaClient (buildEnvelope)
import Shikigami.Sink.Wire (CreateSignalReq (..), SignalResponse (..))
import Shikigami.SinkAuthSpec qualified as SinkAuthSpec
import Shikigami.SinkHonestySpec qualified as SinkHonestySpec
import Shikigami.SinkIntentSpec qualified as SinkIntentSpec
import Shikigami.Trigger.Schedule (isDue, nextDue, parseCron)
import Shikigami.Trigger.Stream (IncludeAgentActors (IncludeAgentActors), matchesStream, matchesStreamWith)
import Shikigami.WireCompatSpec qualified as WireCompatSpec
import Shikigami.WorkerSessionPositionSpec qualified as WorkerSessionPositionSpec
import Shikigami.WorkspaceActionProofSpec qualified as WorkspaceActionProofSpec
import Shikigami.WorkspaceAdapterSpec qualified as WorkspaceAdapterSpec
import Shikigami.WorkspaceCatalogSpec qualified as WorkspaceCatalogSpec
import Shikigami.WorkspaceInstructionsSpec qualified as WorkspaceInstructionsSpec
import Shikigami.WorkspaceProcessPolicySpec qualified as WorkspaceProcessPolicySpec
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

main :: IO ()
main =
  defaultMain
    ( testGroup
        "shikigami"
        [ testGroup "Sink" [kizashiTests, kawaTests, danwaTests, traceHeaderTests],
          testGroup "Trigger" [scheduleTests, streamTests, danwaIntegrationTests],
          WorkspaceCatalogSpec.tests,
          WorkspaceInstructionsSpec.tests,
          WorkspaceProcessPolicySpec.tests,
          WorkspaceAdapterSpec.tests,
          WorkspaceActionProofSpec.tests,
          AgentLoaderSpec.tests,
          ApprovalNotificationSpec.tests,
          ObjectiveSpec.tests,
          AppConfigSpec.tests,
          AttestationContractsSpec.tests,
          BehaviorInputSpec.tests,
          BehaviorProviderSpec.tests,
          BehaviorRetrySpec.tests,
          BehaviorToolSpec.tests,
          CapabilityOverlaySpec.tests,
          CapabilityProviderSpec.tests,
          DecisionContractSpec.tests,
          DecisionModelCatalogSpec.tests,
          DecisionRunnerSpec.tests,
          DelegateContextSpec.tests,
          DelegationBatchSpec.tests,
          ExecutionPositionSpec.tests,
          ExecutionPolicySpec.tests,
          ExecutionResourcesSpec.tests,
          WorkerSessionPositionSpec.tests,
          ExecutionSelectionSpec.tests,
          DirectorySpec.tests,
          EnqueueHardeningSpec.tests,
          KeiroSpecificationSpec.tests,
          KanmonClientSpec.tests,
          LogSpec.tests,
          PackageArchitectureSpec.tests,
          PracticeReviewEvidenceSpec.tests,
          PracticeReviewSpec.tests,
          RouterCatalogSpec.tests,
          RouterDecisionSpec.tests,
          RouterDeclarationSpec.tests,
          SinkHonestySpec.tests,
          SinkIntentSpec.tests,
          SinkAuthSpec.tests,
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
      subject = Subject {kind = subjType, subjectId = "i-1"},
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
      directory = disabledDirectoryHandle,
      runId = "run-1",
      ordinal = 0,
      kizashi = kz,
      kawa = kw,
      danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_test"},
      kanmon = KanmonConfig {baseUrl = "http://localhost:1"},
      rei = Sink.ReiConfig {baseUrl = Nothing},
      http = testSinkHttp,
      traceHeaders = [],
      danwaTarget = Nothing,
      recipientOverride = Nothing,
      conversationKey = Nothing,
      triggeringActivityId = Nothing,
      occurredAt = Nothing,
      receipts = Nothing,
      logger = Log.silentLogger,
      grants = StaticGrants defaultGrantTable
    }

dummyKawa :: KawaConfig
dummyKawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = "shinzui/shikigami"}

dummyKizashi :: KizashiConfig
dummyKizashi = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "recipient_default"}

ctxForDanwa :: AgentIdentity -> DanwaConfig -> Maybe DanwaTarget -> IO SinkContext
ctxForDanwa ident danwa target = do
  sinkHttp <- testSinkHttpFor danwa
  pure
    ( (ctxFor ident dummyKizashi dummyKawa)
        { danwa = danwa,
          http = sinkHttp,
          danwaTarget = target
        }
    )

kizashiTests :: TestTree
kizashiTests =
  testGroup
    "KizashiSignal"
    [ testCase "allow-listed: POSTs a CreateSignalReq, outcome Delivered" $ do
        ref <- newIORef []
        testWithApplication (pure (stubKizashiApp ref)) $ \port -> do
          let kz = KizashiConfig {baseUrl = testBaseUrl port, defaultRecipient = "recipient_default"}
              ctx = ctxFor (compatibilityIdentity "heartbeat") kz dummyKawa
          r <- Sink.dispatch ctx sampleKizashiSink sampleOutput
          (.outcome) r @?= Delivered "sig_stub"
          reqs <- readIORef ref
          assertEqual "one signal recorded" 1 (length reqs)
          case reqs of
            (CreateSignalReq {source = s} : _) -> s @?= "shinzui/shikigami"
            [] -> assertBool "expected a recorded signal" False,
      testCase "denied: skipped and recorded, no POST" $ do
        ref <- newIORef []
        testWithApplication (pure (stubKizashiApp ref)) $ \port -> do
          let kz = KizashiConfig {baseUrl = testBaseUrl port, defaultRecipient = "recipient_default"}
              ctx = ctxFor (compatibilityIdentity "intruder") kz dummyKawa
          r <- Sink.dispatch ctx sampleKizashiSink sampleOutput
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
          let kw = KawaConfig {baseUrl = testBaseUrl port, sourceSegment = "shinzui/shikigami"}
              dummyKz = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "r"}
              ctx = ctxFor (compatibilityIdentity "heartbeat") dummyKz kw
              sink = KawaDigest {subjectType = "heartbeat", verb = "heartbeat.tick"}
          r1 <- Sink.dispatch ctx sink sampleOutput
          r2 <- Sink.dispatch ctx sink sampleOutput
          case ((.outcome) r1, (.outcome) r2) of
            (Delivered a1, Delivered a2) -> do
              assertBool "activity id non-empty" (not (Text.null a1))
              assertEqual "same activity id on retry (deduplicated)" a1 a2
            other -> assertBool ("expected two Delivered, got " <> show other) False
          m <- readIORef store
          assertEqual "exactly one stored (source, source_event_id)" 1 (Map.size m),
      testCase "context refs are bounded to closed schemes and deduplicated before ingest" do
        let ctx = ctxFor (compatibilityIdentity "heartbeat") dummyKizashi dummyKawa
            sink = KawaDigest {subjectType = "practice-review", verb = "practice-review.completed"}
            output =
              object
                [ "context_refs"
                    .= [ object ["scheme" .= ("mori://" :: Text), "ref" .= ("shinzui/example" :: Text)],
                         object ["scheme" .= ("mori://" :: Text), "ref" .= ("shinzui/example" :: Text)],
                         object ["scheme" .= ("activity://" :: Text), "ref" .= ("practice-review/review-1" :: Text)]
                       ]
                ]
        buildEnvelope ctx sink output >>= \case
          Left problem -> assertFailure (show problem)
          Right ActivityEnvelope {contextRefs} ->
            contextRefs
              @?= [ ContextRef {scheme = "mori://", ref = "shinzui/example"},
                    ContextRef {scheme = "activity://", ref = "practice-review/review-1"}
                  ],
      testCase "malformed context refs fail permanently before HTTP" do
        store <- newIORef (Map.empty :: Map (Text, Text) Text)
        testWithApplication (pure (kawaDoorwayApplication store)) $ \port -> do
          let kw = KawaConfig {baseUrl = testBaseUrl port, sourceSegment = "shinzui/shikigami"}
              ctx = ctxFor (compatibilityIdentity "heartbeat") dummyKizashi kw
              sink = KawaDigest {subjectType = "practice-review", verb = "practice-review.completed"}
              output = object ["context_refs" .= [object ["scheme" .= ("https://" :: Text), "ref" .= ("example.invalid" :: Text)]]]
          result <- Sink.dispatch ctx sink output
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
          let cfg = DanwaConfig {baseUrl = testBaseUrl port, agentParticipant = "part_agent_test"}
              target = Just DanwaTarget {conversationId = "conv_target", parentMessageId = Just "msg_parent"}
              sink = DanwaConversation {topic = "support"}
          ctx <- ctxForDanwa (compatibilityIdentity "heartbeat") cfg target
          r <- Sink.dispatch ctx sink (object ["reply" .= ("reply text" :: Text)])
          (.outcome) r @?= Delivered "msg_reply"
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
              sink = DanwaConversation {topic = "support"}
          ctx <- ctxForDanwa (compatibilityIdentity "heartbeat") cfg Nothing
          r <- Sink.dispatch ctx sink (object ["summary" .= ("fresh thread text" :: Text)])
          (.outcome) r @?= Delivered "msg_stub"
          reqs <- readIORef ref
          assertEqual "one danwa message recorded" 1 (length reqs)
          postedContent reqs @?= Just "[support]\nfresh thread text",
      testCase "a declaration with no topic is denied before opening an unaddressable thread" do
        ref <- newIORef []
        testWithApplication (pure (stubDanwaApp ref)) \port -> do
          let cfg = DanwaConfig {baseUrl = testBaseUrl port, agentParticipant = "part_agent_test"}
              sink = DanwaConversation {topic = ""}
          ctx <- ctxForDanwa (compatibilityIdentity "heartbeat") cfg Nothing
          result <- Sink.dispatch ctx sink (object ["summary" .= ("fresh thread text" :: Text)])
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
          let kw = KawaConfig {baseUrl = testBaseUrl port, sourceSegment = "shinzui/shikigami"}
              ctx = (ctxFor (compatibilityIdentity "heartbeat") dummyKizashi kw) {traceHeaders = sampleTraceHeaders}
              sink = KawaDigest {subjectType = "heartbeat", verb = "heartbeat.tick"}
          _ <- Sink.dispatch ctx sink sampleOutput
          assertCapturedTraceHeaders headers,
      testCase "kizashi receives only the generated W3C trace headers" do
        headers <- newIORef []
        signals <- newIORef []
        testWithApplication (pure (captureHeaders headers (stubKizashiApp signals))) \port -> do
          let kz = KizashiConfig {baseUrl = testBaseUrl port, defaultRecipient = "recipient_default"}
              ctx = (ctxFor (compatibilityIdentity "heartbeat") kz dummyKawa) {traceHeaders = sampleTraceHeaders}
          _ <- Sink.dispatch ctx sampleKizashiSink sampleOutput
          assertCapturedTraceHeaders headers,
      testCase "rei receives only the generated W3C trace headers" do
        headers <- newIORef []
        testWithApplication (pure (captureHeaders headers acceptingReiApp)) \port -> do
          let ctx =
                (ctxFor (compatibilityIdentity "heartbeat") dummyKizashi dummyKawa)
                  { rei = Sink.ReiConfig {baseUrl = Just (testBaseUrl port)},
                    traceHeaders = sampleTraceHeaders
                  }
              sink = ReiAction {intentionId = "int_trace", note = "trace this action"}
          _ <- Sink.dispatch ctx sink sampleOutput
          assertCapturedTraceHeaders headers,
      testCase "danwa receives only the generated W3C trace headers" do
        headers <- newIORef []
        messages <- newIORef []
        testWithApplication (pure (captureHeaders headers (stubDanwaApp messages))) \port -> do
          let cfg = DanwaConfig {baseUrl = testBaseUrl port, agentParticipant = "part_agent_test"}
              target = Just DanwaTarget {conversationId = "conv_target", parentMessageId = Just "msg_parent"}
              sink = DanwaConversation {topic = "support"}
          baseCtx <- ctxForDanwa (compatibilityIdentity "heartbeat") cfg target
          _ <- Sink.dispatch ((baseCtx & #traceHeaders .~ (sampleTraceHeaders))) sink sampleOutput
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
