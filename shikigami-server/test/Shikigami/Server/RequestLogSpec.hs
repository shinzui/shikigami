module Shikigami.Server.RequestLogSpec (tests) where

import Control.Exception (bracket, throwIO)
import Control.Monad (void)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Types
  ( hAuthorization,
    hCookie,
    hUserAgent,
    internalServerError500,
    ok200,
  )
import Network.Wai
  ( Application,
    Request,
    Response,
    defaultRequest,
    queryString,
    rawPathInfo,
    rawQueryString,
    requestHeaders,
    requestMethod,
    responseHeaders,
    responseLBS,
    responseStatus,
    setRequestBodyChunks,
  )
import OpenTelemetry.Exporter.InMemory (inMemoryListExporter)
import OpenTelemetry.Instrumentation.Wai (newOpenTelemetryWaiMiddleware')
import OpenTelemetry.Metric qualified as Metric
import OpenTelemetry.Propagator (setGlobalTextMapPropagator)
import OpenTelemetry.Propagator.W3CTraceContext (w3cTraceContextPropagator)
import OpenTelemetry.Trace qualified as Trace
import Shikigami.Server.App (exceptionBoundary)
import Shikigami.Server.RequestLog (includeProductionRequest, requestLogMiddlewareWith)
import Shikigami.Server.Telemetry (boundedTelemetryMiddleware)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "request log"
    [ testCase "safe fields, trace correlation, redaction, errors, and health exclusion" requestLogContract
    ]

requestLogContract :: IO ()
requestLogContract = do
  (processor, spansRef) <- inMemoryListExporter
  bracket
    (Trace.createTracerProvider [processor] Trace.emptyTracerProviderOptions)
    (\provider -> void (Trace.shutdownTracerProvider provider Nothing))
    \provider -> do
      setGlobalTextMapPropagator w3cTraceContextPropagator
      meter <- Metric.getMeter Metric.noopMeterProvider "shikigami-request-log-test"
      otelMiddleware <- newOpenTelemetryWaiMiddleware' provider meter
      linesRef <- newIORef []
      responsesRef <- newIORef []
      let sink line = modifyIORef' linesRef (<> [line])
          application =
            boundedTelemetryMiddleware
              otelMiddleware
              ( requestLogMiddlewareWith
                  sink
                  includeProductionRequest
                  (exceptionBoundary fixtureApplication)
              )

      runRequest application (secretRequest "/ok") responsesRef
      runRequest application (plainRequest "/boom") responsesRef
      runRequest application (plainRequest "/health/live") responsesRef
      runRequest application (plainRequest "/health/ready") responsesRef

      lines' <- readIORef linesRef
      length lines' @?= 2
      assertBool "each sink value is exactly one complete line" (all oneCompleteLine lines')
      assertNoSecrets lines'
      spans <- readIORef spansRef
      assertBool
        "HTTP spans retained the raw query secret"
        (not ("QUERY_SECRET" `isInfixOf` show spans))

      (successLine, failureLine) <-
        case lines' of
          [successLine, failureLine] -> pure (successLine, failureLine)
          _ -> assertFailure "expected exactly the successful and failing request lines"
      success <- decodeObject successLine
      failure <- decodeObject failureLine
      objectKeys success
        @?= sort
          [ "duration_ms",
            "method",
            "path",
            "span_id",
            "status",
            "time",
            "trace_id",
            "user_agent",
            "user_agent_truncated"
          ]
      objectKeys failure
        @?= sort ["duration_ms", "method", "path", "span_id", "status", "time", "trace_id"]
      fieldText "method" success @?= "POST"
      fieldText "path" success @?= "/ok"
      fieldNumber "status" success @?= 200
      fieldNumber "status" failure @?= 500
      fieldText "path" failure @?= "/boom"
      Text.length (fieldText "user_agent" success) @?= 256
      fieldBool "user_agent_truncated" success @?= True
      assertBool "duration is non-negative" (fieldDouble "duration_ms" success >= 0)

      -- The incoming remote trace id survives, while the request span gets its
      -- own child id. The response header injected by the same WAI context must
      -- name exactly the ids written to the request line.
      fieldText "trace_id" success @?= incomingTraceId
      Text.length (fieldText "span_id" success) @?= 16
      responses <- readIORef responsesRef
      (successResponse, failureResponse) <-
        case responses of
          successResponse : failureResponse : _ -> pure (successResponse, failureResponse)
          _ -> assertFailure "expected responses for the included requests"
      let successTraceparent = lookup "traceparent" (responseHeaders successResponse)
          expectedTraceparent =
            Text.encodeUtf8
              ("00-" <> fieldText "trace_id" success <> "-" <> fieldText "span_id" success <> "-01")
      successTraceparent @?= Just expectedTraceparent
      responseStatus failureResponse @?= internalServerError500

fixtureApplication :: Application
fixtureApplication request respond
  | rawPathInfo request == "/boom" = throwIO (userError "escaped DETAIL_SECRET")
  | rawPathInfo request == "/ok",
    rawQueryString request /= "?token=QUERY_SECRET"
      || lookup hAuthorization (requestHeaders request) /= Just "Bearer AUTH_SECRET" =
      throwIO (userError "telemetry middleware did not restore the application request")
  | otherwise = respond (responseLBS ok200 [] "ok")

runRequest :: Application -> Request -> IORef [Response] -> IO ()
runRequest application request responses =
  void $
    application request \response -> do
      modifyIORef' responses (<> [response])
      pure (error "opaque ResponseReceived is not inspected by this test")

secretRequest :: ByteString -> Request
secretRequest path =
  setRequestBodyChunks (pure "BODY_SECRET") $
    (plainRequest path)
      { requestMethod = "POST",
        rawQueryString = "?token=QUERY_SECRET",
        queryString = [("token", Just "QUERY_SECRET")],
        requestHeaders =
          [ (hAuthorization, "Bearer AUTH_SECRET"),
            (hCookie, "session=COOKIE_SECRET"),
            ("x-private", "HEADER_SECRET"),
            (hUserAgent, Text.encodeUtf8 (Text.replicate 300 "\x754c")),
            ("traceparent", Text.encodeUtf8 incomingTraceparent)
          ]
      }

plainRequest :: ByteString -> Request
plainRequest path = defaultRequest {rawPathInfo = path}

incomingTraceId :: Text
incomingTraceId = "11111111111111111111111111111111"

incomingTraceparent :: Text
incomingTraceparent = "00-" <> incomingTraceId <> "-2222222222222222-01"

oneCompleteLine :: ByteString -> Bool
oneCompleteLine line =
  ByteString8.count '\n' line == 1
    && ByteString8.last line == '\n'

assertNoSecrets :: [ByteString] -> IO ()
assertNoSecrets lines' =
  mapM_
    ( \secret ->
        assertBool
          ("request log retained planted secret " <> ByteString8.unpack secret)
          (not (secret `ByteString.isInfixOf` rendered))
    )
    ["BODY_SECRET", "QUERY_SECRET", "AUTH_SECRET", "COOKIE_SECRET", "HEADER_SECRET", "DETAIL_SECRET"]
  where
    rendered = ByteString.concat lines'

decodeObject :: ByteString -> IO (KeyMap.KeyMap Value)
decodeObject line =
  case eitherDecodeStrict' line of
    Right (Object object) -> pure object
    Right other -> assertFailure ("expected JSON object, got " <> show other)
    Left failure -> assertFailure ("request line is not JSON: " <> failure)

objectKeys :: KeyMap.KeyMap Value -> [String]
objectKeys = sort . fmap Key.toString . KeyMap.keys

fieldText :: Text -> KeyMap.KeyMap Value -> Text
fieldText name object =
  case KeyMap.lookup (Key.fromText name) object of
    Just (String value) -> value
    other -> error ("expected text field " <> Text.unpack name <> ", got " <> show other)

fieldNumber :: Text -> KeyMap.KeyMap Value -> Int
fieldNumber name object =
  case KeyMap.lookup (Key.fromText name) object of
    Just (Number value) -> round value
    other -> error ("expected number field " <> Text.unpack name <> ", got " <> show other)

fieldDouble :: Text -> KeyMap.KeyMap Value -> Double
fieldDouble name object =
  case KeyMap.lookup (Key.fromText name) object of
    Just (Number value) -> realToFrac value
    other -> error ("expected number field " <> Text.unpack name <> ", got " <> show other)

fieldBool :: Text -> KeyMap.KeyMap Value -> Bool
fieldBool name object =
  case KeyMap.lookup (Key.fromText name) object of
    Just (Bool value) -> value
    other -> error ("expected boolean field " <> Text.unpack name <> ", got " <> show other)
