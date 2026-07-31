-- | Runtime OpenTelemetry wiring for Shikigami.
--
-- == Why this module reads the environment directly
--
-- Everything else in this repository resolves configuration through
-- "Shikigami.App.Config"; @getEnv@ and @lookupEnv@ are forbidden outside that
-- declaration. This module is the one documented exception, and the exception is
-- narrow: the @OTEL_*@ variables are a cross-language specification owned by the
-- OpenTelemetry SDK, which parses them itself in
-- @loadExporterEnvironmentVariables@ below. Re-declaring them as Shikigami
-- settings would create a second, subtly different parser for names an operator
-- already knows from every other service in the fleet, and would not remove the
-- SDK's own reads. The single @lookupEnv@ here only asks whether the standard
-- endpoint variable is set at all, so that a process with no collector runs
-- against a no-op provider instead of failing to build an exporter.
--
-- A Shikigami-specific tracing *policy* — whether to trace at all, sampling
-- decisions — would be an ordinary Settei setting. The standard variables stay
-- SDK-owned.
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
