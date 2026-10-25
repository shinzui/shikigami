-- | Every error the server can produce is RFC 9457 problem details.
--
-- Three of the four ways Servant can fail a request are exercised end to end
-- against a real Warp server, because each one is produced by a different
-- mechanism and a unit test of the formatter would not prove they are wired up:
--
--   * a path that matches nothing (the not-found formatter, reached through the
--     application 'Servant.Server.Context');
--   * a path that exists but not for the requested method (Servant's own empty
--     405, rewritten by the WAI middleware);
--   * a successful probe, which must /not/ be problem details — a 200 or a 503
--     from a health check is a status report, not an error.
--
-- The fourth way, a handler aborting with a problem, has no route to trigger it
-- yet; the function it would go through is checked directly.
module Shikigami.Server.ProblemSpec (tests) where

import Data.Aeson (Value (Object), decode, toJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.List (sort)
import Data.Text (Text)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (hContentType, statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import OpenTelemetry.Trace qualified as Trace
import Servant.Health (ProbeVerdict (Healthy))
import Servant.Server (ServerError (..))
import Shikigami.Agent.Catalog (emptyCatalog)
import Shikigami.Api.Problem (ProblemCode (..), ProblemDetails (..), problem)
import Shikigami.App.Config (defaultAppConfig)
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Log qualified as Log
import Shikigami.Server.App (shikigamiApplication)
import Shikigami.Server.Boot (newServerEnvWith)
import Shikigami.Server.Seam (problemServerError)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "problem details"
    [ testCase "an unmatched path answers 404 problem+json" do
        (status, contentType, body) <- request "GET" "/no-such-thing"
        status @?= 404
        contentType @?= Just "application/problem+json"
        assertProblemBody body "not_found" 404 False,
      testCase "a wrong method on an existing path answers 405 problem+json" do
        (status, contentType, body) <- request "POST" "/health/live"
        status @?= 405
        contentType @?= Just "application/problem+json"
        assertProblemBody body "method_not_allowed" 405 False,
      testCase "a passing probe is plain JSON, not problem details" do
        (status, contentType, body) <- request "GET" "/health/live"
        status @?= 200
        contentType @?= Just "application/json;charset=utf-8"
        case decode body :: Maybe Value of
          Just (Object o) ->
            sort (fmap Key.toString (KeyMap.keys o))
              @?= (["check", "failingSince", "status"] :: [String])
          other -> assertBool ("expected a probe body object, got " <> show other) False,
      testCase "a handler failure renders the same body through one function" do
        let serverError = problemServerError Unavailable "The store is not reachable."
        errHTTPCode serverError @?= 503
        assertEqual
          "content type declared once"
          [("Content-Type", "application/problem+json")]
          (errHeaders serverError)
        assertProblemBody (errBody serverError) "unavailable" 503 True,
      testCase "the encoded body is exactly the declared key set" $
        case toJSON (problem Internal "boom") of
          Object o ->
            sort (fmap Key.toString (KeyMap.keys o))
              @?= (["code", "detail", "retryable", "status", "title", "type"] :: [String])
          other -> assertBool ("expected a JSON object, got " <> show other) False
    ]

-- | Send one request to the assembled application and report what came back.
--
-- Both probe checks pass: these cases are about routing and error rendering,
-- and the probe matrix itself is covered by @servant-health@'s conformance kit.
request :: LBS8.ByteString -> String -> IO (Int, Maybe LBS8.ByteString, LBS.ByteString)
request method path =
  do
    provider <- Trace.createTracerProvider [] Trace.emptyTracerProviderOptions
    let tracer = Trace.makeTracer provider "shikigami-server-test" Trace.tracerOptions
        application = shikigamiApplication (newServerEnvWith tracer defaultAppConfig Log.silentLogger emptyCatalog disabledDirectoryHandle passing passing)
    testWithApplication (pure application) \port -> do
      manager <- Http.newManager Http.defaultManagerSettings
      initial <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
      response <- Http.httpLbs initial {Http.method = LBS.toStrict method} manager
      let contentType = LBS.fromStrict <$> lookup hContentType (Http.responseHeaders response)
      pure (statusCode (Http.responseStatus response), contentType, Http.responseBody response)
  where
    passing = pure Healthy

-- | Assert the decoded body is the problem the caller expects.
assertProblemBody :: LBS.ByteString -> Text -> Int -> Bool -> IO ()
assertProblemBody body expectedCode expectedStatus expectedRetryable =
  case decode body :: Maybe ProblemDetails of
    Nothing -> assertBool ("body is not ProblemDetails: " <> LBS8.unpack body) False
    Just details -> do
      (.code) details @?= expectedCode
      (.status) details @?= expectedStatus
      (.retryable) details @?= expectedRetryable
      (.problemType) details @?= "about:blank"
      assertBool "title is non-empty" ((.title) details /= "")
      assertBool "detail is non-empty" ((.detail) details /= "")
