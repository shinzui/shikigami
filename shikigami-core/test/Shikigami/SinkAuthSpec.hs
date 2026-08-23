module Shikigami.SinkAuthSpec (tests) where

import Control.Exception (AsyncException (UserInterrupt), throwIO, try)
import Danwa.Client qualified as Danwa
import Danwa.Conversation.Api qualified as Conversation
import Data.Aeson (Value (String), encode, object)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Client
  ( ManagerSettings (managerModifyRequest),
    defaultManagerSettings,
    newManager,
  )
import Network.HTTP.Types
  ( Header,
    Status,
    hAuthorization,
    hContentType,
    hLocation,
    status200,
    status302,
    status401,
    status429,
  )
import Network.Wai (Application, requestHeaders, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Servant.Client (ClientEnv)
import Settei (answer, defaultResolveOptions, resolve)
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.App.Config (AppConfig (..), ByteLimit, CredentialRef (..), appConfig, byteLimitBytes, environmentBindings, mkByteLimit)
import Shikigami.Sink.Auth
  ( BearerToken,
    CredentialFailure (..),
    CredentialFailureReason (CredentialBackendUnavailable),
    TokenSource (..),
    credentialToken,
    staticTokenSource,
  )
import Shikigami.Sink.Config (DanwaConfig (..))
import Shikigami.Sink.Http
  ( HttpEnv (..),
    HttpFailure (..),
    HttpFailureReason (..),
    HttpLimits (..),
    SinkCredentials (..),
    SinkHttp (..),
    newSinkHttp,
    newSinkManager,
    postJSON,
    postJSONWithHeaders,
    renderHttpFailure,
    runDanwaClient,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "outbound sink authentication"
    [ headerTests,
      failureTests,
      limitTests,
      redirectTests,
      danwaTests
    ]

headerTests :: TestTree
headerTests =
  testGroup
    "headers"
    [ testCase "a configured source injects exactly one bearer header" do
        received <- newIORef []
        testWithApplication (pure (recordHeaders received)) \port -> do
          env <- testEnv (Just (staticTokenSource expectedToken)) defaultLimits
          result <- postJSONWithHeaders env [(hAuthorization, "Bearer caller-value"), (hContentType, "text/plain")] (localBaseUrl port) (object [])
          assertRight result
          headers <- readIORef received
          fmap snd (filter ((== hAuthorization) . fst) headers) @?= [expectedHeader],
      testCase "an absent source sends no authorization header" do
        received <- newIORef []
        testWithApplication (pure (recordHeaders received)) \port -> do
          env <- testEnv Nothing defaultLimits
          result <- postJSON env (localBaseUrl port) (object [])
          assertRight result
          headers <- readIORef received
          lookup hAuthorization headers @?= Nothing
    ]

failureTests :: TestTree
failureTests =
  testGroup
    "fail closed"
    [ testCase "credential lookup failure issues no request and retains no secret text" do
        calls <- newIORef (0 :: Int)
        testWithApplication (pure (countRequests calls)) \port -> do
          let failure =
                CredentialFailure
                  { reference = CredentialRef "credentials.sinks.kawa.token",
                    reason = CredentialBackendUnavailable
                  }
              source = TokenSource (pure (Left failure))
          env <- testEnv (Just source) defaultLimits
          result <- postJSON env (localBaseUrl port) (object [])
          result @?= Left (TransientHttpFailure (CredentialUnavailable failure))
          readIORef calls >>= (@?= 0)
          assertBool "failure rendering must not contain the planted token" (not (rawToken `Text.isInfixOf` either renderHttpFailure (const "") result)),
      testCase "status classes are typed rather than parsed from prose" do
        env <- testEnv Nothing defaultLimits
        testWithApplication (pure (statusApplication status401)) \port ->
          postJSON env (localBaseUrl port) (object []) >>= (@?= Left (PermanentHttpFailure (UnexpectedStatus 401)))
        testWithApplication (pure (statusApplication status429)) \port ->
          postJSON env (localBaseUrl port) (object []) >>= (@?= Left (TransientHttpFailure (UnexpectedStatus 429))),
      testCase "asynchronous cancellation is not converted to a transport failure" do
        manager <-
          newManager
            defaultManagerSettings
              { managerModifyRequest = const (throwIO UserInterrupt)
              }
        let env = HttpEnv {manager, token = Nothing, limits = defaultLimits}
        result <- try @AsyncException (postJSON env "http://127.0.0.1:1" (object []))
        result @?= Left UserInterrupt
    ]

limitTests :: TestTree
limitTests =
  testGroup
    "bounded bodies"
    [ testCase "request accepts the exact boundary and rejects one byte over before IO" do
        calls <- newIORef (0 :: Int)
        let exact = String (Text.replicate 1_022 "a")
            over = String (Text.replicate 1_023 "a")
            limits = limitsAt 1_024 1_024
        LBS.length (encode exact) @?= 1_024
        LBS.length (encode over) @?= 1_025
        testWithApplication (pure (consumeAndCount calls)) \port -> do
          env <- testEnv Nothing limits
          postJSON env (localBaseUrl port) exact >>= assertRight
          postJSON env (localBaseUrl port) over >>= (@?= Left (PermanentHttpFailure (RequestTooLarge 1_025 (requestBytes limits))))
          readIORef calls >>= (@?= 1),
      testCase "response accepts the exact boundary and rejects one byte over" do
        env <- testEnv Nothing (limitsAt 1_024 1_024)
        testWithApplication (pure (sizedResponse 1_024)) \port ->
          postJSON env (localBaseUrl port) (object []) >>= assertRight
        testWithApplication (pure (sizedResponse 1_025)) \port ->
          postJSON env (localBaseUrl port) (object []) >>= \case
            Left (PermanentHttpFailure (ResponseTooLarge limit)) -> byteLimit limit @?= 1_024
            other -> assertFailure ("expected an oversized response, got " <> show other)
    ]

redirectTests :: TestTree
redirectTests =
  testGroup
    "redirects"
    [ testCase "a redirect is permanent and its target receives no request or credential" do
        targetCalls <- newIORef (0 :: Int)
        testWithApplication (pure (countRequests targetCalls)) \targetPort ->
          testWithApplication (pure (redirectApplication targetPort)) \redirectPort -> do
            env <- testEnv (Just (staticTokenSource expectedToken)) defaultLimits
            postJSON env (localBaseUrl redirectPort) (object []) >>= (@?= Left (PermanentHttpFailure (UnexpectedStatus 302)))
            readIORef targetCalls >>= (@?= 0)
    ]

danwaTests :: TestTree
danwaTests =
  testGroup
    "danwa servant client"
    [ testCase "the dedicated manager injects the danwa token" do
        received <- newIORef []
        testWithApplication (pure (danwaApplication received danwaResponse)) \port -> do
          clientEnv <- danwaClientEnv port defaultLimits (Just (staticTokenSource expectedToken))
          result <- runDanwaClient clientEnv (Danwa.startConversation startConversation)
          assertRight result
          headers <- readIORef received
          lookup hAuthorization headers @?= Just expectedHeader,
      testCase "danwa response accepts its exact boundary and rejects one byte over" do
        let exact = padJson 1_024 danwaResponse
            over = padJson 1_025 danwaResponse
            limits = limitsAt 1_024 1_024
        testWithApplication (pure (danwaApplicationDiscardHeaders exact)) \port -> do
          clientEnv <- danwaClientEnv port limits Nothing
          runDanwaClient clientEnv (Danwa.startConversation startConversation) >>= assertRight
        testWithApplication (pure (danwaApplicationDiscardHeaders over)) \port -> do
          clientEnv <- danwaClientEnv port limits Nothing
          runDanwaClient clientEnv (Danwa.startConversation startConversation) >>= \case
            Left (PermanentHttpFailure (ResponseTooLarge limit)) -> byteLimit limit @?= 1_024
            Left other -> assertFailure ("expected an oversized danwa response, got " <> show other)
            Right _ -> assertFailure "an oversized danwa response succeeded",
      testCase "danwa rejects an oversized generated request before the stub sees it" do
        calls <- newIORef (0 :: Int)
        let limits = limitsAt 1_024 1_024
            oversized =
              Conversation.StartConversationRequest
                { Conversation.startedBy = Text.replicate 2_000 "a",
                  Conversation.kind = "thread",
                  Conversation.parentConversationId = Nothing
                }
        testWithApplication (pure (countRequests calls)) \port -> do
          clientEnv <- danwaClientEnv port limits Nothing
          runDanwaClient clientEnv (Danwa.startConversation oversized) >>= \case
            Left (PermanentHttpFailure RequestTooLarge {}) -> pure ()
            Left other -> assertFailure ("expected an oversized danwa request, got " <> show other)
            Right _ -> assertFailure "an oversized danwa request succeeded"
          readIORef calls >>= (@?= 0)
    ]

expectedToken :: BearerToken
expectedToken = tokenFromConfig rawToken

rawToken :: Text
rawToken = "sink-s3cr3t-auth-spec-42"

expectedHeader :: ByteString
expectedHeader = "Bearer sink-s3cr3t-auth-spec-42"

tokenFromConfig :: Text -> BearerToken
tokenFromConfig value =
  case answer (resolve defaultResolveOptions [source] appConfig) of
    Right AppConfig {kawaToken = Just secret} -> credentialToken secret
    Right _ -> error "test token did not resolve"
    Left _ -> error "test token configuration was rejected"
  where
    source = environmentSource environmentBindings (envSnapshot [("SHIKIGAMI_KAWA_TOKEN", value)])

defaultLimits :: HttpLimits
defaultLimits = limitsAt 8_388_608 8_388_608

limitsAt :: Int -> Int -> HttpLimits
limitsAt requestLimit responseLimit =
  HttpLimits
    { requestBytes = checkedLimit requestLimit,
      responseBytes = checkedLimit responseLimit
    }

checkedLimit :: Int -> ByteLimit
checkedLimit = either (error . Text.unpack) id . mkByteLimit

byteLimit :: ByteLimit -> Int
byteLimit = byteLimitBytes

testEnv :: Maybe TokenSource -> HttpLimits -> IO HttpEnv
testEnv source httpLimits = do
  manager <- newSinkManager
  pure HttpEnv {manager, token = source, limits = httpLimits}

danwaClientEnv :: Int -> HttpLimits -> Maybe TokenSource -> IO ClientEnv
danwaClientEnv port httpLimits source = do
  let config = DanwaConfig {baseUrl = localBaseUrl port, agentParticipant = "part_agent_test"}
      credentials = SinkCredentials {kawa = Nothing, kizashi = Nothing, kanmon = Nothing, danwa = source}
  newSinkHttp httpLimits credentials config >>= \case
    Left failure -> assertFailure ("failed to build danwa client: " <> show failure)
    Right SinkHttp {danwa} -> pure danwa

startConversation :: Conversation.StartConversationRequest
startConversation =
  Conversation.StartConversationRequest
    { Conversation.startedBy = "part_agent_test",
      Conversation.kind = "thread",
      Conversation.parentConversationId = Nothing
    }

danwaResponse :: LBS.ByteString
danwaResponse =
  "{\"conversationId\":\"conv_stub\",\"status\":\"active\",\"kind\":\"thread\",\"startedBy\":\"part_agent_test\",\"parentConversationId\":\"\"}"

padJson :: Int -> LBS.ByteString -> LBS.ByteString
padJson size bytes
  | remaining < 0 = error "fixture JSON exceeds its requested size"
  | otherwise = bytes <> LBS.replicate (fromIntegral remaining) 32
  where
    remaining = size - fromIntegral (LBS.length bytes)

recordHeaders :: IORef [Header] -> Application
recordHeaders received request respond = do
  _ <- strictRequestBody request
  writeIORef received (requestHeaders request)
  respond (responseLBS status200 [(hContentType, "application/json")] "{}")

countRequests :: IORef Int -> Application
countRequests calls _request respond = do
  modifyIORef' calls (+ 1)
  respond (responseLBS status200 [(hContentType, "application/json")] "{}")

consumeAndCount :: IORef Int -> Application
consumeAndCount calls request respond = do
  _ <- strictRequestBody request
  modifyIORef' calls (+ 1)
  respond (responseLBS status200 [(hContentType, "application/json")] "{}")

statusApplication :: Status -> Application
statusApplication status _request respond = respond (responseLBS status [] "")

sizedResponse :: Int -> Application
sizedResponse size _request respond = respond (responseLBS status200 [] (LBS.replicate (fromIntegral size) 97))

redirectApplication :: Int -> Application
redirectApplication port _request respond =
  respond (responseLBS status302 [(hLocation, baseUrlBytes port)] "")

danwaApplication :: IORef [Header] -> LBS.ByteString -> Application
danwaApplication received body request respond = do
  _ <- strictRequestBody request
  writeIORef received (requestHeaders request)
  respond (responseLBS status200 [(hContentType, "application/json")] body)

danwaApplicationDiscardHeaders :: LBS.ByteString -> Application
danwaApplicationDiscardHeaders body _request respond =
  respond (responseLBS status200 [(hContentType, "application/json")] body)

localBaseUrl :: Int -> Text
localBaseUrl port = "http://127.0.0.1:" <> Text.pack (show port)

baseUrlBytes :: Int -> ByteString
baseUrlBytes = TextEncoding.encodeUtf8 . localBaseUrl

assertRight :: (Show e) => Either e a -> IO ()
assertRight = \case
  Left failure -> assertFailure ("expected Right, got " <> show failure)
  Right _ -> pure ()
