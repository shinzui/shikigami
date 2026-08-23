module Shikigami.Server.KawaStubSpec (tests) where

import Data.Aeson (Value, decode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (hAuthorization, hContentType, statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import Settei (answer, defaultResolveOptions, resolve)
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.Api.Problem (ProblemDetails (..))
import Shikigami.App.Config
  ( AppConfig (..),
    appConfig,
    environmentBindings,
  )
import Shikigami.Sink.Auth (BearerToken, credentialToken, staticTokenSource)
import Shikigami.Sink.Http
  ( HttpEnv (..),
    HttpFailure,
    HttpLimits (..),
    newSinkManager,
    postJSON,
  )
import Shikigami.Sink.KawaStub (stubKawaApplication)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "stub-kawa authentication"
    [ testCase "the configured token accepts a matching client request" do
        accepted <- newIORef Map.empty
        testWithApplication (pure (stubKawaApplication accepted Nothing (Just expectedToken))) \port -> do
          httpEnv <- authenticatedEnv expectedToken
          result <- postJSON httpEnv (ingestUrl port) ingestRequest :: IO (Either HttpFailure LBS.ByteString)
          case result of
            Left failure -> assertFailure ("matching request failed: " <> show failure)
            Right _ -> pure ()
          Map.size <$> readIORef accepted >>= (@?= 1),
      testCase "a missing token returns an RFC 9457 401 before decoding the body" do
        accepted <- newIORef Map.empty
        response <- rejectedRequest accepted Nothing
        assertUnauthorized response
        readIORef accepted >>= (@?= Map.empty),
      testCase "a wrong token returns an RFC 9457 401 without ingesting" do
        accepted <- newIORef Map.empty
        response <- rejectedRequest accepted (Just "Bearer definitely-not-the-token")
        assertUnauthorized response
        readIORef accepted >>= (@?= Map.empty)
    ]

type Accepted = Map (Text, Text) Text

expectedToken :: BearerToken
expectedToken = tokenFromConfig "stub-kawa-expected-token"

tokenFromConfig :: Text -> BearerToken
tokenFromConfig value =
  case answer (resolve defaultResolveOptions [source] appConfig) of
    Right AppConfig {kawaToken = Just secret} -> credentialToken secret
    Right _ -> error "test token did not resolve"
    Left _ -> error "test token configuration was rejected"
  where
    source = environmentSource environmentBindings (envSnapshot [("SHIKIGAMI_KAWA_TOKEN", value)])

authenticatedEnv :: BearerToken -> IO HttpEnv
authenticatedEnv token = do
  manager <- newSinkManager
  let AppConfig {httpRequestMaxBytes, httpResponseMaxBytes} = defaultConfig
      limits = HttpLimits {requestBytes = httpRequestMaxBytes, responseBytes = httpResponseMaxBytes}
  pure HttpEnv {manager, token = Just (staticTokenSource token), limits}
  where
    defaultConfig = case answer (resolve defaultResolveOptions [] appConfig) of
      Right config -> config
      Left _ -> error "default application configuration was rejected"

rejectedRequest :: IORef Accepted -> Maybe ByteString -> IO (Http.Response LBS.ByteString)
rejectedRequest accepted authorization =
  testWithApplication (pure (stubKawaApplication accepted Nothing (Just expectedToken))) \port -> do
    manager <- Http.newManager Http.defaultManagerSettings
    initial <- Http.parseRequest (Text.unpack (ingestUrl port))
    let request =
          initial
            { Http.method = "POST",
              Http.requestBody = Http.RequestBodyBS "not-json-and-must-not-be-decoded",
              Http.requestHeaders = maybe [] (\value -> [(hAuthorization, value)]) authorization
            }
    Http.httpLbs request manager

assertUnauthorized :: Http.Response LBS.ByteString -> IO ()
assertUnauthorized response = do
  statusCode (Http.responseStatus response) @?= 401
  lookup hContentType (Http.responseHeaders response) @?= Just "application/problem+json"
  case decode (Http.responseBody response) of
    Nothing -> assertFailure "401 body was not problem details"
    Just ProblemDetails {code, status, retryable} -> do
      code @?= "unauthorized"
      status @?= 401
      retryable @?= False

ingestUrl :: Int -> Text
ingestUrl port = "http://127.0.0.1:" <> Text.pack (show port) <> "/v1/sources/shikigami-test/events"

ingestRequest :: Value
ingestRequest =
  object
    [ "verb" .= ("tested" :: Text),
      "actor" .= object ["kind" .= ("agent" :: Text), "id" .= ("agent_test" :: Text), "session" .= (Nothing :: Maybe Text)],
      "subject" .= object ["type" .= ("test" :: Text), "id" .= ("subject_test" :: Text)],
      "payload" .= object [],
      "context_refs" .= ([] :: [Value]),
      "source_event_id" .= ("event_test" :: Text),
      "occurred_at" .= ("2026-08-23T00:00:00Z" :: Text)
    ]
