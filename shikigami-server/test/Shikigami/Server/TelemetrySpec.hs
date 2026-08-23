module Shikigami.Server.TelemetrySpec (tests) where

import Control.Monad (void)
import Data.IORef (newIORef, readIORef, writeIORef)
import OpenTelemetry.Exporter.InMemory (assertMetricNamed, inMemoryMetricExporter)
import OpenTelemetry.Exporter.Span (ExportResult (Success), SpanExporter (..))
import OpenTelemetry.Metric qualified as Metric
import OpenTelemetry.Processor.Batch.Span (batchProcessor, batchTimeoutConfig)
import OpenTelemetry.Resource (emptyMaterializedResources)
import OpenTelemetry.Trace qualified as Trace
import Shikigami.Server.Telemetry (ServerTelemetry (..), makeServerTelemetry, releaseServerTelemetry)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)

tests :: TestTree
tests =
  testGroup
    "telemetry shutdown"
    [ testCase "release exports queued spans and metrics before provider teardown" do
        spanExported <- newIORef False
        let exporter =
              SpanExporter
                { spanExporterExport = \_ -> writeIORef spanExported True >> pure Success,
                  spanExporterShutdown = pure Metric.ShutdownSuccess,
                  spanExporterForceFlush = pure Metric.FlushSuccess
                }
        processor <- batchProcessor batchTimeoutConfig exporter
        tracerProvider <- Trace.createTracerProvider [processor] Trace.emptyTracerProviderOptions

        (metricExporter, metricsExported) <- inMemoryMetricExporter
        (meterProvider, _environment) <-
          Metric.createMeterProvider
            emptyMaterializedResources
            Metric.defaultSdkMeterProviderOptions {Metric.metricExporter = Just metricExporter}
        let telemetry@ServerTelemetry {tracer} = makeServerTelemetry tracerProvider meterProvider
        meter <- Metric.getMeter meterProvider "shikigami-server-shutdown-test"
        counter <- Metric.meterCreateCounterInt64 meter "shikigami.server.shutdown_test" Nothing Nothing Metric.defaultAdvisoryParameters

        Trace.inSpan tracer "queued-before-shutdown" Trace.defaultSpanArguments (pure ())
        Metric.counterAdd counter 1 Metric.emptyAttributes
        releaseServerTelemetry telemetry

        readIORef spanExported >>= assertBool "queued span was not exported during release"
        void (assertMetricNamed metricsExported "shikigami.server.shutdown_test")
    ]
