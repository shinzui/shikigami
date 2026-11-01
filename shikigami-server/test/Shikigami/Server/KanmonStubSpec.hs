module Shikigami.Server.KanmonStubSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Aeson (decode, encode)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (readIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (hAuthorization, hContentType, statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import Settei (answer, defaultResolveOptions, resolve)
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.Activity.Coordinate (activityCoordinate)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Api.Problem (ProblemDetails (..))
import Shikigami.App.Config (AppConfig (..), appConfig, environmentBindings)
import Shikigami.Sink.Auth (BearerToken, credentialToken)
import Shikigami.Sink.KanmonStub (StubKanmonState (..), newStubKanmonState, stubKanmonApplication)
import Shikigami.Sink.Wire (EgressActionRequest (..), EgressActionResponse (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "stub-kanmon"
    [ testCase "accepts the exact authenticated route and response shape" do
        state <- newStubKanmonState
        testWithApplication (pure (stubKanmonApplication state (Just expectedToken) (Set.map declarationCoordinate allowed))) \port -> do
          response <- postAction port route (Just expectedAuthorization) (encode actionRequest)
          statusCode (Http.responseStatus response) @?= 200
          let EgressActionResponse {activityId, verb} = decodeResponse response
          assertBool "activity id is a bounded fixture id" ("act_" `Text.isPrefixOf` activityId)
          verb @?= "conversation.reply_sent"
          (.acceptedEffects) <$> readIORef state >>= (@?= 1),
      testCase "authenticates before attempting to parse a body" do
        state <- newStubKanmonState
        testWithApplication (pure (stubKanmonApplication state (Just expectedToken) (Set.map declarationCoordinate allowed))) \port -> do
          missing <- postAction port route Nothing "not-json"
          wrong <- postAction port route (Just "Bearer wrong-token") "not-json"
          assertUnauthorized missing
          assertUnauthorized wrong
          (.acceptedEffects) <$> readIORef state >>= (@?= 0),
      testCase "rejects malformed JSON, forbidden destinations, and unknown routes" do
        state <- newStubKanmonState
        testWithApplication (pure (stubKanmonApplication state (Just expectedToken) (Set.map declarationCoordinate allowed))) \port -> do
          malformed <- postAction port route (Just expectedAuthorization) "not-json"
          forbidden <- postAction port route (Just expectedAuthorization) (encode ((actionRequest & #conversationKey .~ ("conv_forbidden"))))
          missing <- postAction port "/channels/zendesk/actions/reply_to_conversation" (Just expectedAuthorization) (encode actionRequest)
          statusCode (Http.responseStatus malformed) @?= 400
          statusCode (Http.responseStatus forbidden) @?= 403
          statusCode (Http.responseStatus missing) @?= 404
          (.acceptedEffects) <$> readIORef state >>= (@?= 0),
      testCase "same idempotency key returns one id and records one accepted effect" do
        state <- newStubKanmonState
        testWithApplication (pure (stubKanmonApplication state (Just expectedToken) (Set.map declarationCoordinate allowed))) \port -> do
          first <- postAction port route (Just expectedAuthorization) (encode actionRequest)
          second <- postAction port route (Just expectedAuthorization) (encode actionRequest)
          decodeResponse first @?= decodeResponse second
          snapshot <- readIORef state
          (.acceptedEffects) snapshot @?= 1
          length ((.idempotency) snapshot) @?= 1,
      testCase "requests without idempotency keys remain fresh effects" do
        state <- newStubKanmonState
        testWithApplication (pure (stubKanmonApplication state (Just expectedToken) (Set.map declarationCoordinate allowed))) \port -> do
          first <- postAction port route (Just expectedAuthorization) (encode ((actionRequest & #idempotencyKey .~ (Nothing))))
          second <- postAction port route (Just expectedAuthorization) (encode ((actionRequest & #idempotencyKey .~ (Nothing))))
          assertBool "fresh requests receive different ids" ((.activityId) (decodeResponse first) /= (.activityId) (decodeResponse second))
          (.acceptedEffects) <$> readIORef state >>= (@?= 2)
    ]

allowed :: Set.Set Text
allowed = Set.singleton "conv_55012"

route :: String
route = "/channels/intercom/actions/reply_to_conversation"

actionRequest :: EgressActionRequest
actionRequest =
  EgressActionRequest
    { conversationKey = "conv_55012",
      content = "reply text",
      idempotencyKey = Just "channel-reply:run-1:0",
      triggeringActivityId = Just "act_1"
    }

expectedToken :: BearerToken
expectedToken =
  case answer (resolve defaultResolveOptions [source] appConfig) of
    Right AppConfig {kanmonToken = Just secret} -> credentialToken secret
    Right _ -> error "test Kanmon token did not resolve"
    Left _ -> error "test Kanmon token configuration was rejected"
  where
    source = environmentSource environmentBindings (envSnapshot [("SHIKIGAMI_KANMON_TOKEN", "stub-kanmon-expected-token")])

expectedAuthorization :: ByteString
expectedAuthorization = "Bearer stub-kanmon-expected-token"

postAction :: Int -> String -> Maybe ByteString -> LBS.ByteString -> IO (Http.Response LBS.ByteString)
postAction port path authorization body = do
  manager <- Http.newManager Http.defaultManagerSettings
  initial <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
  let request =
        initial
          { Http.method = "POST",
            Http.requestBody = Http.RequestBodyLBS body,
            Http.requestHeaders =
              [(hContentType, "application/json")]
                <> maybe [] (\value -> [(hAuthorization, value)]) authorization
          }
  Http.httpLbs request manager

decodeResponse :: Http.Response LBS.ByteString -> EgressActionResponse
decodeResponse response =
  case decode (Http.responseBody response) of
    Just decoded -> decoded
    Nothing -> error "stub response did not decode as EgressActionResponse"

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
