-- | Runtime OpenTelemetry wiring for Shikigami.
module Shikigami.Telemetry
  ( withRunTracer,
  )
where

import Control.Exception (bracket)
import Data.String (fromString)
import OpenTelemetry.Exporter.OTLP.Span (loadExporterEnvironmentVariables, otlpExporter)
import OpenTelemetry.Processor.Batch.Span (batchProcessor, batchTimeoutConfig)
import OpenTelemetry.Trace.Core qualified as Otel
import Shibuya.Telemetry.Effect (Tracer)
import System.Environment (lookupEnv)

-- | Build a worker tracer from @OTEL_EXPORTER_OTLP_ENDPOINT@ when configured.
-- Without an endpoint, the action runs against a no-op provider so callers do
-- not need separate tracing and non-tracing code paths.
withRunTracer :: (Tracer -> IO a) -> IO a
withRunTracer action = do
  endpoint <- lookupEnv "OTEL_EXPORTER_OTLP_ENDPOINT"
  case endpoint of
    Nothing -> bracket mkNoopProvider shutdownProvider (action . makeTracer)
    Just _ -> bracket mkOtlpProvider shutdownProvider (action . makeTracer)
  where
    makeTracer provider =
      Otel.makeTracer provider (fromString "shikigami.worker") Otel.tracerOptions

    shutdownProvider provider = do
      _ <- Otel.shutdownTracerProvider provider Nothing
      pure ()

mkNoopProvider :: IO Otel.TracerProvider
mkNoopProvider =
  Otel.createTracerProvider [] Otel.emptyTracerProviderOptions

mkOtlpProvider :: IO Otel.TracerProvider
mkOtlpProvider = do
  cfg <- loadExporterEnvironmentVariables
  exporter <- otlpExporter cfg
  processor <- batchProcessor batchTimeoutConfig exporter
  Otel.createTracerProvider [processor] Otel.emptyTracerProviderOptions
