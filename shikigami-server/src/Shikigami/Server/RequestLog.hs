-- | Bounded, allow-listed production request logging.
--
-- The middleware deliberately owns a smaller vocabulary than either WAI or
-- OpenTelemetry.  A request carries many values that are unsafe to retain
-- (bodies, cookies, authorization, query values, and arbitrary headers); none
-- of those values can enter the object constructed here.
module Shikigami.Server.RequestLog
  ( requestLogMiddleware,
    requestLogMiddlewareWith,
    includeProductionRequest,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import GHC.Clock (getMonotonicTimeNSec)
import Network.HTTP.Types (hUserAgent, statusCode)
import Network.Wai (Middleware, Request, rawPathInfo, requestHeaders, requestMethod, responseStatus)
import OpenTelemetry.Context qualified as Context
import OpenTelemetry.Instrumentation.Wai (requestContext)
import OpenTelemetry.Trace.Core qualified as Trace
import OpenTelemetry.Trace.Id (Base (Base16), spanIdBaseEncodedText, traceIdBaseEncodedText)
import System.IO (stderr)

-- | Log included requests to stderr with one write per complete JSON line.
requestLogMiddleware :: (Request -> Bool) -> Middleware
requestLogMiddleware = requestLogMiddlewareWith (ByteString.hPut stderr)

-- | The injectable sink used by tests and by 'requestLogMiddleware'.
--
-- The sink receives a complete, newline-terminated object. Keeping the render
-- outside the sink makes it impossible for concurrent requests to interleave
-- fragments when the sink performs one handle write.
requestLogMiddlewareWith :: (ByteString -> IO ()) -> (Request -> Bool) -> Middleware
requestLogMiddlewareWith writeLine include app request respond
  | not (include request) = app request respond
  | otherwise = do
      startedAt <- getMonotonicTimeNSec
      app request \response -> do
        finishedAt <- getMonotonicTimeNSec
        now <- getCurrentTime
        correlation <- traceFields request
        let durationMs = fromIntegral (finishedAt - startedAt) / 1_000_000 :: Double
            fields =
              [ "time" Aeson..= iso8601Show now,
                "method" Aeson..= decode (requestMethod request),
                "path" Aeson..= decode (rawPathInfo request),
                "status" Aeson..= statusCode (responseStatus response),
                "duration_ms" Aeson..= durationMs
              ]
                <> correlation
                <> userAgentFields request
            line = LazyByteString.toStrict (Aeson.encode (Aeson.object fields)) <> "\n"
        writeLine line
        respond response

-- | Exclude only the two exact probe paths. Nearby paths remain observable.
includeProductionRequest :: Request -> Bool
includeProductionRequest request =
  rawPathInfo request /= "/health/live"
    && rawPathInfo request /= "/health/ready"

traceFields :: Request -> IO [Pair]
traceFields request =
  case requestContext request >>= Context.lookupSpan of
    Nothing -> pure []
    Just span' -> do
      context <- Trace.getSpanContext span'
      pure
        if Trace.isValid context
          then
            [ "trace_id" Aeson..= traceIdBaseEncodedText Base16 (Trace.traceId context),
              "span_id" Aeson..= spanIdBaseEncodedText Base16 (Trace.spanId context)
            ]
          else []

userAgentFields :: Request -> [Pair]
userAgentFields request =
  case lookup hUserAgent (requestHeaders request) of
    Nothing -> []
    Just raw ->
      let decoded = decode raw
          bounded = Text.take userAgentLimit decoded
          truncated = Text.length decoded > userAgentLimit
       in [ "user_agent" Aeson..= bounded,
            "user_agent_truncated" Aeson..= truncated
          ]

userAgentLimit :: Int
userAgentLimit = 256

decode :: ByteString -> Text
decode = Text.decodeUtf8With lenientDecode
