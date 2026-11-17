-- | The Danwa client through the kernel's typed-client runner
-- ("Shikigami.Sink.Http"): the dedicated manager injects the token and holds
-- requests and responses to their byte limits. These cases moved from the
-- kernel's sink authentication suite with the Danwa client (plan 135, M6), so
-- no stock suite links a Kikan client.
module Kikan.Shikigami.Binding.TypedClientSpec (tests) where

import Danwa.Client qualified as Danwa
import Danwa.Conversation.Api qualified as Conversation
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types (Header, hAuthorization, hContentType, status200)
import Network.Wai (Application, requestHeaders, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Servant.Client (ClientEnv, mkClientEnv, parseBaseUrl)
import Settei (answer, defaultResolveOptions, resolve)
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.App.Config (AppConfig (..), ByteLimit, appConfig, byteLimitBytes, environmentBindings, mkByteLimit)
import Shikigami.Sink.Auth (BearerToken, TokenSource, credentialToken, staticTokenSource)
import Shikigami.Sink.Http (HttpFailure (..), HttpFailureReason (..), HttpLimits (..), newTypedClientManager, runTypedClient)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests = danwaTests

danwaTests :: TestTree
danwaTests =
  testGroup
    "danwa servant client"
    [ testCase "the dedicated manager injects the danwa token" do
        received <- newIORef []
        testWithApplication (pure (danwaApplication received danwaResponse)) \port -> do
          clientEnv <- danwaClientEnv port defaultLimits (Just (staticTokenSource expectedToken))
          result <- runTypedClient clientEnv (Danwa.startConversation startConversation)
          assertRight result
          headers <- readIORef received
          lookup hAuthorization headers @?= Just expectedHeader,
      testCase "danwa response accepts its exact boundary and rejects one byte over" do
        let exact = padJson 1_024 danwaResponse
            over = padJson 1_025 danwaResponse
            limits = limitsAt 1_024 1_024
        testWithApplication (pure (danwaApplicationDiscardHeaders exact)) \port -> do
          clientEnv <- danwaClientEnv port limits Nothing
          runTypedClient clientEnv (Danwa.startConversation startConversation) >>= assertRight
        testWithApplication (pure (danwaApplicationDiscardHeaders over)) \port -> do
          clientEnv <- danwaClientEnv port limits Nothing
          runTypedClient clientEnv (Danwa.startConversation startConversation) >>= \case
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
          runTypedClient clientEnv (Danwa.startConversation oversized) >>= \case
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
    Right AppConfig {databaseUrl = Just secret} -> credentialToken secret
    Right _ -> error "test token did not resolve"
    Left _ -> error "test token configuration was rejected"
  where
    source = environmentSource environmentBindings (envSnapshot [("PG_CONNECTION_STRING", value)])

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

danwaClientEnv :: Int -> HttpLimits -> Maybe TokenSource -> IO ClientEnv
danwaClientEnv port httpLimits source = do
  manager <- newTypedClientManager httpLimits source
  case parseBaseUrl (Text.unpack (localBaseUrl port)) of
    Nothing -> assertFailure "failed to parse the danwa base URL"
    Just base -> pure (mkClientEnv manager base)

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

countRequests :: IORef Int -> Application
countRequests calls _request respond = do
  modifyIORef' calls (+ 1)
  respond (responseLBS status200 [(hContentType, "application/json")] "{}")

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

assertRight :: (Show e) => Either e a -> IO ()
assertRight = \case
  Left failure -> assertFailure ("expected Right, got " <> show failure)
  Right _ -> pure ()
