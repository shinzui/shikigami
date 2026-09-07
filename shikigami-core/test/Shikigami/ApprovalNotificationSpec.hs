module Shikigami.ApprovalNotificationSpec (tests) where

import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (secondsToNominalDiffTime)
import Data.UUID qualified as UUID
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Network.HTTP.Types (Status, hContentType, status200, status204, status403, status404, status500)
import Network.Wai (Application, pathInfo, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Shikigami.Agent.Approval (ApprovalChannel (..), ApprovalRequest (..), ReviewRequestId (..))
import Shikigami.Agent.Approval.Notification (approvalNotifier, renderApprovalMessage)
import Shikigami.Agent.Approval.Workflow (ApprovalNotificationError (..), ApprovalNotifier (..))
import Shikigami.Agent.Decl (Priority (High), SignalType (AgentRequest))
import Shikigami.Fixture.SinkHttp (testSinkHttpFor)
import Shikigami.Log qualified as Log
import Shikigami.Sink.Config (DanwaConfig (..), KizashiConfig (..))
import Shikigami.Sink.Wire qualified as Wire
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ApprovalNotification"
    [ testCase "rendered ask is bounded and carries both identities and CLI forms" do
        let message =
              renderApprovalMessage
                reviewId
                awakeableId
                (secondsToNominalDiffTime 60)
                request {prompt = Text.replicate 2_000 "p"}
        mapM_
          (\fragment -> assertBool ("missing approval message fragment: " <> Text.unpack fragment) (fragment `Text.isInfixOf` message))
          [ "Review: review_test",
            awakeableToken,
            "Deadline: 60 seconds",
            "--approve",
            "--reject \"reason\"",
            "…"
          ]
        assertBool "approval message stays bounded" (Text.length message < 4_000),
      testCase "Danwa notifier opens a thread and posts the human-visible ask" do
        messages <- newIORef []
        testWithApplication (pure (danwaApplication messages)) \port -> do
          let danwaConfig = DanwaConfig {baseUrl = localBaseUrl port, agentParticipant = "part_agent_test"}
              kizashiConfig = KizashiConfig {baseUrl = "http://127.0.0.1:1", defaultRecipient = "recipient:test"}
          sinkHttp <- testSinkHttpFor danwaConfig
          let notifier = approvalNotifier Log.silentLogger sinkHttp danwaConfig kizashiConfig
          outcome <- (.postAsk) notifier reviewId awakeableId (secondsToNominalDiffTime 60) request
          outcome @?= Right ()
          posted <- readIORef messages
          assertBool "Danwa receives the review id" (any (Text.isInfixOf "review_test") posted)
          assertBool "Danwa receives the opaque token" (any (Text.isInfixOf awakeableToken) posted),
      testCase "Danwa notifier classifies retryable and permanent HTTP failures" do
        testWithApplication (pure (failingDanwaApplication status500)) \transientPort -> do
          notifier <- notifierForDanwa transientPort
          (.postAsk) notifier reviewId awakeableId 60 request >>= \case
            Left TransientNotification {} -> pure ()
            other -> assertFailure ("expected transient Danwa failure, got " <> show other)
        testWithApplication (pure (failingDanwaApplication status403)) \permanentPort -> do
          notifier <- notifierForDanwa permanentPort
          (.postAsk) notifier reviewId awakeableId 60 request >>= \case
            Left PermanentNotification {} -> pure ()
            other -> assertFailure ("expected permanent Danwa failure, got " <> show other),
      testCase "Kizashi notifier emits AgentRequest and classifies HTTP/decode failures" do
        requests <- newIORef []
        testWithApplication (pure (kizashiApplication status200 requests)) \successPort -> do
          notifier <- notifierForKizashi successPort
          (.postAsk) notifier reviewId awakeableId (secondsToNominalDiffTime 60) request {channel = ViaKizashi} >>= (@?= Right ())
          posted <- readIORef requests
          case posted of
            [Wire.CreateSignalReq {Wire.signalType, Wire.priority, Wire.intent, Wire.contextTags}] -> do
              signalType @?= AgentRequest
              priority @?= High
              assertBool "Kizashi request carries review id" ("review_test" `Text.isInfixOf` intent && "review_test" `elem` contextTags)
              assertBool "Kizashi request carries opaque token" (awakeableToken `Text.isInfixOf` intent)
            other -> assertFailure ("expected one Kizashi request, got " <> show other)
        testWithApplication (pure (kizashiApplication status500 requests)) \transientPort -> do
          notifier <- notifierForKizashi transientPort
          (.postAsk) notifier reviewId awakeableId 60 request {channel = ViaKizashi} >>= \case
            Left TransientNotification {} -> pure ()
            other -> assertFailure ("expected transient notification failure, got " <> show other)
        testWithApplication (pure (kizashiApplication status403 requests)) \permanentPort -> do
          notifier <- notifierForKizashi permanentPort
          (.postAsk) notifier reviewId awakeableId 60 request {channel = ViaKizashi} >>= \case
            Left PermanentNotification {} -> pure ()
            other -> assertFailure ("expected permanent notification failure, got " <> show other)
        testWithApplication (pure invalidKizashiApplication) \invalidPort -> do
          notifier <- notifierForKizashi invalidPort
          (.postAsk) notifier reviewId awakeableId 60 request {channel = ViaKizashi} >>= \case
            Left PermanentNotification {} -> pure ()
            other -> assertFailure ("expected permanent decode failure, got " <> show other)
    ]

reviewId :: ReviewRequestId
reviewId = ReviewRequestId "review_test"

awakeableId :: AwakeableId
awakeableId = AwakeableId (maybe (error "invalid approval test UUID") id (UUID.fromText awakeableToken))

awakeableToken :: Text
awakeableToken = "123e4567-e89b-42d3-a456-426614174000"

request :: ApprovalRequest
request =
  ApprovalRequest
    { prompt = "Approve heartbeat sink?",
      context = object ["run" .= ("heartbeat:test" :: Text)],
      channel = ViaDanwa
    }

notifierForKizashi :: Int -> IO ApprovalNotifier
notifierForKizashi port = do
  let danwaConfig = DanwaConfig {baseUrl = "http://127.0.0.1:1", agentParticipant = "part_agent_test"}
      kizashiConfig = KizashiConfig {baseUrl = localBaseUrl port, defaultRecipient = "recipient:test"}
  sinkHttp <- testSinkHttpFor danwaConfig
  pure (approvalNotifier Log.silentLogger sinkHttp danwaConfig kizashiConfig)

notifierForDanwa :: Int -> IO ApprovalNotifier
notifierForDanwa port = do
  let danwaConfig = DanwaConfig {baseUrl = localBaseUrl port, agentParticipant = "part_agent_test"}
      kizashiConfig = KizashiConfig {baseUrl = "http://127.0.0.1:1", defaultRecipient = "recipient:test"}
  sinkHttp <- testSinkHttpFor danwaConfig
  pure (approvalNotifier Log.silentLogger sinkHttp danwaConfig kizashiConfig)

danwaApplication :: IORef [Text] -> Application
danwaApplication messages request' respond =
  case (requestMethod request', pathInfo request') of
    ("POST", ["conversations"]) ->
      respond
        ( responseLBS
            status200
            [(hContentType, "application/json")]
            "{\"conversationId\":\"conv_stub\",\"status\":\"active\",\"kind\":\"thread\",\"startedBy\":\"part_agent_test\",\"parentConversationId\":\"\"}"
        )
    ("POST", ["conversations", "conv_stub", "participants"]) -> respond (responseLBS status204 [] "")
    ("POST", ["conversations", "conv_stub", "messages"]) -> do
      body <- strictRequestBody request'
      case eitherDecode @Value body of
        Right value -> do
          modifyIORef' messages (extractContent value :)
          respond
            ( responseLBS
                status200
                [(hContentType, "application/json")]
                "{\"messageId\":\"msg_stub\",\"conversationId\":\"conv_stub\",\"author\":\"part_agent_test\",\"content\":\"approval\",\"postedAt\":\"2026-08-23T00:00:00Z\"}"
            )
        Left err -> respond (responseLBS status500 [] (LazyByteString.pack err))
    _ -> respond (responseLBS status404 [] "not found")

failingDanwaApplication :: Status -> Application
failingDanwaApplication status _request respond = respond (responseLBS status [] "failure")

extractContent :: Value -> Text
extractContent value =
  case eitherDecode (encode value) of
    Right (PostBody content) -> content
    Left _ -> ""

newtype PostBody = PostBody Text

instance Aeson.FromJSON PostBody where
  parseJSON = Aeson.withObject "PostBody" (fmap PostBody . (Aeson..: "content"))

kizashiApplication :: Status -> IORef [Wire.CreateSignalReq] -> Application
kizashiApplication status requests request' respond = do
  body <- strictRequestBody request'
  case eitherDecode @Wire.CreateSignalReq body of
    Left err -> respond (responseLBS status500 [] (LazyByteString.pack err))
    Right value -> do
      modifyIORef' requests (value :)
      if status == status200
        then respond (responseLBS status200 [(hContentType, "application/json")] "{\"signalId\":\"sig_stub\",\"lifecycleState\":\"active\"}")
        else respond (responseLBS status [] "failure")

invalidKizashiApplication :: Application
invalidKizashiApplication request' respond = do
  _ <- strictRequestBody request'
  respond (responseLBS status200 [(hContentType, "application/json")] "not-json")

localBaseUrl :: Int -> Text
localBaseUrl port = "http://127.0.0.1:" <> Text.pack (show port)
