-- | Process-lifetime OpenTelemetry wiring for worker executables.
--
-- == Why this module reads the environment directly
--
-- The standard @OTEL_*@ variables remain SDK-owned. The one direct endpoint
-- lookup preserves Shikigami's established behavior: without an explicit OTLP
-- endpoint the process installs no-op providers instead of trying the SDK's
-- default localhost exporter.
module Shikigami.Telemetry
  ( withRunTelemetry,
  )
where

import Control.Exception (bracket, onException)
import Control.Monad (void)
import Data.Text (Text)
import Keiro.Telemetry (KeiroMetrics, keiroInstrumentationLibrary, newKeiroMetrics)
import OpenTelemetry.Metric qualified as Metric
import OpenTelemetry.Trace qualified as Trace
import Shibuya.Telemetry.Effect (Tracer)
import Shikigami.Telemetry.Metrics
  ( ShikigamiMetrics,
    newShikigamiMetrics,
    shikigamiInstrumentationLibrary,
  )
import System.Environment (lookupEnv)

data Providers = Providers
  { tracer :: !Trace.TracerProvider,
    meter :: !Metric.MeterProvider
  }

-- | Acquire one tracer and meter provider for a long-running workers process,
-- construct both Keiro's and Shikigami's instruments, and flush everything
-- before provider shutdown.
withRunTelemetry :: Text -> (Tracer -> Maybe KeiroMetrics -> ShikigamiMetrics -> IO a) -> IO a
withRunTelemetry scope action =
  bracket acquire release \Providers {tracer = tracerProvider, meter = meterProvider} -> do
    keiroMeter <- Metric.getMeter meterProvider keiroInstrumentationLibrary
    shikigamiMeter <- Metric.getMeter meterProvider shikigamiInstrumentationLibrary
    keiroMetrics <- newKeiroMetrics keiroMeter
    shikigamiMetrics <- newShikigamiMetrics shikigamiMeter
    action (makeTracer scope tracerProvider) (Just keiroMetrics) shikigamiMetrics

acquire :: IO Providers
acquire = do
  endpoint <- lookupEnv "OTEL_EXPORTER_OTLP_ENDPOINT"
  case endpoint of
    Nothing -> do
      tracer <- newNoopTracerProvider
      Trace.setGlobalTracerProvider tracer
      Metric.setGlobalMeterProvider Metric.noopMeterProvider
      pure Providers {tracer, meter = Metric.noopMeterProvider}
    Just _ -> do
      tracer <- Trace.initializeGlobalTracerProvider
      meter <-
        Metric.initializeGlobalMeterProvider
          `onException` void (Trace.shutdownTracerProvider tracer Nothing)
      pure Providers {tracer, meter}

release :: Providers -> IO ()
release Providers {tracer, meter} = do
  void (Trace.forceFlushTracerProvider tracer Nothing)
  void (Metric.forceFlushMeterProvider meter Nothing)
  void (Trace.shutdownTracerProvider tracer Nothing)
  void (Metric.shutdownMeterProvider meter Nothing)
  replacement <- newNoopTracerProvider
  Trace.setGlobalTracerProvider replacement
  Metric.setGlobalMeterProvider Metric.noopMeterProvider

newNoopTracerProvider :: IO Trace.TracerProvider
newNoopTracerProvider =
  Trace.createTracerProvider [] Trace.emptyTracerProviderOptions

makeTracer :: Text -> Trace.TracerProvider -> Tracer
makeTracer scope provider =
  Trace.makeTracer
    provider
    Trace.InstrumentationLibrary
      { Trace.libraryName = scope,
        Trace.libraryVersion = "0.1.0.0",
        Trace.librarySchemaUrl = "",
        Trace.libraryAttributes = Metric.emptyAttributes
      }
    Trace.tracerOptions
