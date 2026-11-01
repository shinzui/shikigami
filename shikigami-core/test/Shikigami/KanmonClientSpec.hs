module Shikigami.KanmonClientSpec (tests) where

import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.Foldable (traverse_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.Id qualified as SinkSession
import Network.HTTP.Types (Header, Status, hAuthorization, hContentType, mkStatus, status200)
import Network.Wai (Application, pathInfo, requestHeaders, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Settei (answer, defaultResolveOptions, resolve)
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.Activity qualified as Activity
import Shikigami.Activity.Coordinate
import Shikigami.Activity.Coordinate (activityCoordinate)
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.App.Config (AppConfig, CredentialRef (..), appConfig, environmentBindings)
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Fixture.SinkHttp (testHttpLimits, testSinkHttp)
import Shikigami.Log qualified as Log
import Shikigami.Sink (SinkOutcome (..), SinkResult (..), dispatch)
import Shikigami.Sink.Auth (CredentialFailure (..), CredentialFailureReason (CredentialBackendUnavailable), TokenSource (..))
import Shikigami.Sink.Config (DanwaConfig (..), KanmonConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Sink.Coordinate (parseSinkSession, zeroSinkOrdinal)
import Shikigami.Sink.GrantStore (GrantSource (StaticGrants))
import Shikigami.Sink.Http (HttpEnv (..), HttpFailure (..), HttpFailureReason (..), SinkCredentials (..), SinkHttp (..), credentialsFromConfig, newSinkManager)
import Shikigami.Sink.KanmonClient
import Shikigami.Sink.Permission (SinkKind (SChannelEgress))
import Shikigami.Sink.Types (SinkContext (..))
import Shikigami.Sink.Wire (EgressActionRequest (..), EgressActionResponse (..))
import Shikigami.Trigger.Schedule (parseCron)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Kanmon client"
    [ testCase "request and response JSON match the Kanmon snake-case contract" do
        encode request
          @?= "{\"content\":\"reply text\",\"conversation_key\":\"conv_55012\",\"idempotency_key\":\"shikigami.agent.v2.57c8f321-a02c-5978-aee9-ed2efc3fbfe6:kioku_session_01kvxa7d2cezhs874g3n8dfgme:0\",\"triggering_activity_id\":\"act_1\"}"
        eitherDecode "{\"activity_id\":\"act_reply_1\",\"verb\":\"conversation.reply_sent\"}"
          @?= Right (EgressActionResponse "act_reply_1" "conversation.reply_sent"),
      testCase "conversation resolution follows declaration, output, then activity precedence" do
        let activity = Just triggerActivity
            output = object ["conversation_key" .= ("conv_output" :: Text)]
        resolveConversationKey (egress (Just "conv_static")) activity output @?= Just (declarationCoordinate "conv_static")
        resolveConversationKey (egress Nothing) activity output @?= Just (declarationCoordinate "conv_output")
        resolveConversationKey (egress Nothing) activity (object []) @?= Just (declarationCoordinate "conv_activity")
        resolveConversationKey (egress (Just "  ")) Nothing (object ["conversation_key" .= ("" :: Text)]) @?= Nothing,
      testCase "request construction chooses reply content and stable sink identity" do
        buildEgressRequest sampleContext (object ["reply" .= ("reply text" :: Text), "summary" .= ("ignored" :: Text)])
          @?= Right request
        buildEgressRequest (sampleContextFor Nothing) (object [])
          @?= Left "ChannelEgress requires a resolved conversation key",
      testCase "authenticated post carries trace headers and decodes the acknowledgement" do
        seen <- newIORef []
        testWithApplication (pure (acceptingKanmon seen)) \port -> do
          env <- configuredKanmonEnv
          result <- postEgressWithHeaders env sampleTraceHeaders (KanmonConfig (localBaseUrl port)) (declarationCoordinate "intercom") (declarationCoordinate "reply_to_conversation") request
          result @?= Right (EgressActionResponse "act_reply_1" "conversation.reply_sent")
          requests <- readIORef seen
          case requests of
            [(segments, headers, posted)] -> do
              segments @?= ["channels", "intercom", "actions", "reply_to_conversation"]
              lookup hAuthorization headers @?= Just "Bearer kanmon-test-token"
              lookup "traceparent" headers @?= lookup "traceparent" sampleTraceHeaders
              posted @?= request
            other -> assertFailure ("expected one Kanmon request, got " <> show (length other)),
      testCase "invalid durable routes fail before network IO" do
        calls <- newIORef (0 :: Int)
        testWithApplication (pure (countingApplication calls)) \port -> do
          env <- configuredKanmonEnv
          postEgress env (KanmonConfig (localBaseUrl port)) (declarationCoordinate "inter/com") (declarationCoordinate "reply_to_conversation") request >>= \case
            Left (KanmonUsageError _) -> pure ()
            other -> assertFailure ("expected a usage error, got " <> show other)
          readIORef calls >>= (@?= 0),
      testCase "credential-source failure stays transient and secret-safe" do
        calls <- newIORef (0 :: Int)
        let failure = CredentialFailure {reference = CredentialRef "credentials.sinks.kanmon.token", reason = CredentialBackendUnavailable}
            source = TokenSource (pure (Left failure))
        manager <- newSinkManager
        let env = HttpEnv {manager, token = Just source, limits = testHttpLimits}
        testWithApplication (pure (countingApplication calls)) \port -> do
          result <- postEgress env (KanmonConfig (localBaseUrl port)) (declarationCoordinate "intercom") (declarationCoordinate "reply_to_conversation") request
          result @?= Left (KanmonHttpError (TransientHttpFailure (CredentialUnavailable failure)))
          assertBool "rendering carries no token or request content" (not ("reply text" `Text.isInfixOf` renderKanmonError (either id (const (KanmonUsageError "unexpected")) result)))
          readIORef calls >>= (@?= 0),
      testCase "dispatcher retains the acknowledged activity id" do
        seen <- newIORef []
        testWithApplication (pure (acceptingKanmon seen)) \port -> do
          env <- configuredKanmonEnv
          dispatch (dispatchContext port env (Just "conv_55012")) (egress Nothing) (object ["reply" .= ("reply text" :: Text)])
            >>= (@?= SinkResult SChannelEgress (Delivered (declarationCoordinate "act_reply_1"))),
      testCase "dispatcher preserves the shared permanent and transient classifications" do
        env <- configuredKanmonEnv
        traverse_ (assertStatus env Failed "transient HTTP failure: ") [408, 425, 429, 500, 503]
        traverse_ (assertStatus env PermanentFailure "permanent HTTP failure: ") [400, 401, 403, 404]
        testWithApplication (pure malformedSuccess) \port ->
          dispatch (dispatchContext port env (Just "conv_55012")) (egress Nothing) (object [])
            >>= (@?= SinkResult SChannelEgress (PermanentFailure "decode EgressActionResponse"))
        dispatch (dispatchContext 1 env Nothing) (egress Nothing) (object [])
          >>= (@?= SinkResult SChannelEgress (AuthorizationFailed "invalid coordinates: channel conversation was not resolved before authorization"))
        dispatch (dispatchContext 1 env (Just "conv_55012")) (egress Nothing) (object [])
          >>= (@?= SinkResult SChannelEgress (Failed "transient HTTP failure: transport error"))
    ]

request :: EgressActionRequest
request =
  EgressActionRequest
    { conversationKey = "conv_55012",
      content = "reply text",
      idempotencyKey = Just "shikigami.agent.v2.57c8f321-a02c-5978-aee9-ed2efc3fbfe6:kioku_session_01kvxa7d2cezhs874g3n8dfgme:0",
      triggeringActivityId = Just "act_1"
    }

egress :: Maybe Text -> Sink
egress conversationKey = ChannelEgress {channel = declarationCoordinate ("intercom"), action = declarationCoordinate ("reply_to_conversation"), conversationKey = declarationCoordinate <$> conversationKey}

triggerActivity :: Activity.ActivityEnvelope
triggerActivity =
  Activity.ActivityEnvelope
    { Activity.activityId = activityCoordinate ("act_1"),
      Activity.occurredAt = activityCoordinate ("2026-08-23T12:00:00Z"),
      Activity.source = activityCoordinate ("external/intercom"),
      Activity.actor = Activity.Actor {Activity.kind = either (error . show) id (parseActorKind ("human")), Activity.id = activityCoordinate ("person_1"), Activity.session = fmap activityCoordinate (Nothing)},
      Activity.subject = Activity.Subject {Activity.kind = activityCoordinate ("conversation"), Activity.subjectId = activityCoordinate ("conv_activity")},
      Activity.verb = activityCoordinate ("conversation.message_received"),
      Activity.payload = object [],
      Activity.contextRefs = [],
      Activity.idempotencyKey = activityCoordinate ("message_1")
    }

sampleContext :: SinkContext
sampleContext = sampleContextFor (Just "conv_55012")

sampleContextFor :: Maybe Text -> SinkContext
sampleContextFor conversationKey = sampleContextWith conversationKey (KanmonConfig unreachable) testSinkHttp

sampleContextWith :: Maybe Text -> KanmonConfig -> SinkHttp -> SinkContext
sampleContextWith conversationKey kanmon http =
  SinkContext
    { identity = compatibilityIdentity (fixtureAgentName "channel-reply"),
      directory = disabledDirectoryHandle,
      runId = sinkSessionFixture,
      ordinal = zeroSinkOrdinal,
      kizashi = KizashiConfig {baseUrl = unreachable, defaultRecipient = (declarationCoordinate "recipient")},
      kawa = KawaConfig {baseUrl = unreachable, sourceSegment = (activityCoordinate "shinzui/shikigami")},
      danwa = DanwaConfig {baseUrl = unreachable, agentParticipant = (declarationCoordinate "part_agent_test")},
      kanmon,
      rei = ReiConfig {baseUrl = Nothing},
      http,
      traceHeaders = [],
      danwaTarget = Nothing,
      recipientOverride = Nothing,
      conversationKey = declarationCoordinate <$> conversationKey,
      triggeringActivityId = Just (activityCoordinate "act_1"),
      occurredAt = Nothing,
      receipts = Nothing,
      grants = StaticGrants (Map.mapKeys (compatibilityIdentity . fixtureAgentName) egressGrants),
      logger = Log.silentLogger
    }

dispatchContext :: Int -> HttpEnv -> Maybe Text -> SinkContext
dispatchContext port kanmonEnv conversationKey =
  sampleContextWith conversationKey (KanmonConfig (localBaseUrl port)) (sinkHttpWithKanmon kanmonEnv)

sinkHttpWithKanmon :: HttpEnv -> SinkHttp
sinkHttpWithKanmon kanmon = case testSinkHttp of
  SinkHttp {kawa, kizashi, danwa} -> SinkHttp {kawa, kizashi, kanmon, danwa}

egressGrants :: Map.Map Text (Set.Set SinkKind)
egressGrants = Map.singleton "channel-reply" (Set.singleton SChannelEgress)

configuredKanmonEnv :: IO HttpEnv
configuredKanmonEnv = do
  config <- resolvedConfig
  manager <- newSinkManager
  let SinkCredentials {kanmon} = credentialsFromConfig config
  pure HttpEnv {manager, token = kanmon, limits = testHttpLimits}

resolvedConfig :: IO AppConfig
resolvedConfig =
  case answer (resolve defaultResolveOptions [source] appConfig) of
    Right config -> pure config
    Left failure -> assertFailure ("Kanmon config did not resolve: " <> show failure)
  where
    source = environmentSource environmentBindings (envSnapshot [("SHIKIGAMI_KANMON_TOKEN", "kanmon-test-token")])

type CapturedRequest = ([Text], [Header], EgressActionRequest)

acceptingKanmon :: IORef [CapturedRequest] -> Application
acceptingKanmon seen waiRequest respond = do
  body <- strictRequestBody waiRequest
  case eitherDecode body of
    Left problem -> assertFailure ("test request did not decode: " <> problem)
    Right posted -> do
      modifyIORef' seen ((pathInfo waiRequest, requestHeaders waiRequest, posted) :)
      respond
        ( responseLBS
            status200
            [(hContentType, "application/json")]
            (encode (EgressActionResponse "act_reply_1" "conversation.reply_sent"))
        )

countingApplication :: IORef Int -> Application
countingApplication calls _ respond = do
  modifyIORef' calls (+ 1)
  respond (responseLBS status200 [(hContentType, "application/json")] "{}")

assertStatus :: HttpEnv -> (Text -> SinkOutcome) -> Text -> Int -> IO ()
assertStatus env expected prefix code =
  testWithApplication (pure (statusApplication (mkStatus code "test"))) \port ->
    dispatch (dispatchContext port env (Just "conv_55012")) (egress Nothing) (object [])
      >>= (@?= SinkResult SChannelEgress (expected (prefix <> "unexpected status " <> Text.pack (show code))))

statusApplication :: Status -> Application
statusApplication status _ respond =
  respond (responseLBS status [(hContentType, "application/problem+json")] "{\"detail\":\"sensitive downstream body\"}")

malformedSuccess :: Application
malformedSuccess _ respond =
  respond (responseLBS status200 [(hContentType, "application/json")] "{\"activity_id\":42}")

sampleTraceHeaders :: [Header]
sampleTraceHeaders =
  [ ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"),
    (hAuthorization, "Bearer caller-controlled-token")
  ]

localBaseUrl :: Int -> Text
localBaseUrl port = "http://127.0.0.1:" <> Text.pack (show port)

unreachable :: Text
unreachable = "http://localhost:1"

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

sinkSessionFixture :: SinkSession.SessionId
sinkSessionFixture = either (error . show) id (parseSinkSession "kioku_session_01kvxa7d2cezhs874g3n8dfgme")
