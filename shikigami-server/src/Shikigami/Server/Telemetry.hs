-- | Process-lifetime OpenTelemetry ownership for the HTTP server.
module Shikigami.Server.Telemetry
  ( ServerTelemetry (..),
    withServerTelemetry,
    releaseServerTelemetry,
    makeServerTelemetry,
    boundedTelemetryMiddleware,
  )
where

import Control.Exception (bracket, onException)
import Control.Monad (void)
import Network.HTTP.Types (hUserAgent)
import Network.Wai (Middleware, queryString, rawQueryString, requestHeaders)
import OpenTelemetry.Metric qualified as Metric
import OpenTelemetry.Propagator (setGlobalTextMapPropagator)
import OpenTelemetry.Propagator.W3CTraceContext (w3cTraceContextPropagator)
import OpenTelemetry.Trace qualified as Trace
import System.Environment (lookupEnv)

-- | The providers and tracer shared by middleware and application dependencies.
data ServerTelemetry = ServerTelemetry
  { tracerProvider :: !Trace.TracerProvider,
    meterProvider :: !Metric.MeterProvider,
    tracer :: !Trace.Tracer
  }

-- | Bracket the server providers around the complete listener lifetime.
withServerTelemetry :: (ServerTelemetry -> IO a) -> IO a
withServerTelemetry = bracket acquireServerTelemetry releaseServerTelemetry

-- | Assemble the public bundle around explicitly supplied providers.
--
-- Exported so the lifecycle test can use real in-memory providers while
-- exercising the same release path as production.
makeServerTelemetry :: Trace.TracerProvider -> Metric.MeterProvider -> ServerTelemetry
makeServerTelemetry tracerProvider meterProvider =
  ServerTelemetry
    { tracerProvider,
      meterProvider,
      tracer = makeTracer tracerProvider
    }

-- | Keep secrets and unbounded caller-controlled text out of HTTP span fields.
--
-- The upstream WAI instrumentation records the raw query string and user-agent
-- as span attributes. It still needs propagation and host headers, so it sees
-- a narrow copy with only those unsafe values removed. The inner application
-- receives its original query and headers plus the trace context vault that
-- the instrumentation attached.
boundedTelemetryMiddleware :: Middleware -> Middleware
boundedTelemetryMiddleware telemetry application originalRequest respond =
  telemetry tracedApplication telemetryRequest respond
  where
    telemetryRequest =
      originalRequest
        { rawQueryString = "",
          queryString = [],
          requestHeaders = filter ((/= hUserAgent) . fst) (requestHeaders originalRequest)
        }

    tracedApplication tracedRequest =
      application
        tracedRequest
          { rawQueryString = rawQueryString originalRequest,
            queryString = queryString originalRequest,
            requestHeaders = requestHeaders originalRequest
          }

acquireServerTelemetry :: IO ServerTelemetry
acquireServerTelemetry = do
  endpoint <- lookupEnv "OTEL_EXPORTER_OTLP_ENDPOINT"
  case endpoint of
    Nothing -> do
      tracerProvider <- newNoopTracerProvider
      let meterProvider = Metric.noopMeterProvider
      Trace.setGlobalTracerProvider tracerProvider
      Metric.setGlobalMeterProvider meterProvider
      -- SDK initialization installs the configured OTEL_PROPAGATORS value.
      -- The no-exporter branch still needs the standard W3C default so inbound
      -- correlation works while storage/export remains a no-op.
      setGlobalTextMapPropagator w3cTraceContextPropagator
      pure (makeServerTelemetry tracerProvider meterProvider)
    Just _ -> do
      tracerProvider <- Trace.initializeGlobalTracerProvider
      meterProvider <-
        Metric.initializeGlobalMeterProvider
          `onException` void (Trace.shutdownTracerProvider tracerProvider Nothing)
      pure (makeServerTelemetry tracerProvider meterProvider)

-- | Flush both signals before shutting either provider down.
releaseServerTelemetry :: ServerTelemetry -> IO ()
releaseServerTelemetry ServerTelemetry {tracerProvider, meterProvider} = do
  void (Trace.forceFlushTracerProvider tracerProvider Nothing)
  void (Metric.forceFlushMeterProvider meterProvider Nothing)
  void (Trace.shutdownTracerProvider tracerProvider Nothing)
  void (Metric.shutdownMeterProvider meterProvider Nothing)
  replacement <- newNoopTracerProvider
  Trace.setGlobalTracerProvider replacement
  Metric.setGlobalMeterProvider Metric.noopMeterProvider

newNoopTracerProvider :: IO Trace.TracerProvider
newNoopTracerProvider =
  Trace.createTracerProvider [] Trace.emptyTracerProviderOptions

makeTracer :: Trace.TracerProvider -> Trace.Tracer
makeTracer provider =
  Trace.makeTracer provider "shikigami.server" Trace.tracerOptions
