module Shikigami.TelemetrySpec (tests) where

import Control.Monad (void)
import Data.Foldable (traverse_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified
import Data.Vector qualified as Vector
import OpenTelemetry.Attributes (Attributes, addAttributesFromBuilder, attr, defaultAttributeLimits, emptyAttributes)
import OpenTelemetry.Exporter.InMemory
  ( assertMetricNamed,
    inMemoryMetricExporter,
  )
import OpenTelemetry.Exporter.Metric
import OpenTelemetry.Metric qualified as Metric
import OpenTelemetry.Resource (emptyMaterializedResources)
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Telemetry.Metrics
  ( newShikigamiMetrics,
    recordConsumerRecord,
    recordPackEvent,
    recordPackGauge,
    recordQueueDepth,
    recordRunCompleted,
    recordRunDeadLettered,
    recordRunFailed,
    recordRunRetried,
    recordRunStarted,
    recordStreamDisposition,
    shikigamiInstrumentationLibrary,
  )
import Shikigami.Telemetry.Sampler (SampleTarget (PackGaugeSample, QueueSample), samplePackGaugeWith, sampleTelemetryWith)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests _fixture =
  testGroup
    "Telemetry"
    [ testCase "force-flush exports every Shikigami metric instrument" do
        (exporter, exported) <- inMemoryMetricExporter
        (provider, _env) <-
          Metric.createMeterProvider
            emptyMaterializedResources
            Metric.defaultSdkMeterProviderOptions {Metric.metricExporter = Just exporter}
        meter <- Metric.getMeter provider shikigamiInstrumentationLibrary
        metrics <- newShikigamiMetrics meter
        recordRunStarted metrics "heartbeat" "schedule"
        recordRunCompleted metrics "heartbeat" "schedule"
        recordRunFailed metrics "heartbeat" "schedule"
        recordRunRetried metrics "heartbeat" "schedule"
        recordRunDeadLettered metrics "heartbeat" "schedule"
        recordQueueDepth metrics 3
        recordConsumerRecord metrics "activity.v1"
        recordStreamDisposition metrics "initiative" "skipped" (Just "excerpt-too-short")
        recordPackEvent metrics "initiative" "proposal" [("status", "pending")]
        recordPackGauge metrics "fixture" "backlog" 4

        flushed <- Metric.forceFlushMeterProvider provider Nothing
        assertEqual "provider force-flush" Metric.FlushSuccess flushed
        traverse_
          (void . assertMetricNamed exported)
          [ "shikigami.runs.started",
            "shikigami.runs.completed",
            "shikigami.runs.failed",
            "shikigami.runs.retried",
            "shikigami.runs.dead_lettered",
            "shikigami.queue.depth",
            "shikigami.consumer.records",
            "shikigami.stream.dispositions",
            "shikigami.pack.events",
            "shikigami.pack.gauges"
          ]
        void (Metric.shutdownMeterProvider provider Nothing),
      testCase "a pack gauge is absent until the pack reports a level, and carries only its pack and name" do
        (exporter, exported) <- inMemoryMetricExporter
        (provider, _) <- Metric.createMeterProvider emptyMaterializedResources Metric.defaultSdkMeterProviderOptions {Metric.metricExporter = Just exporter}
        meter <- Metric.getMeter provider shikigamiInstrumentationLibrary
        metrics <- newShikigamiMetrics meter
        let record = recordPackGauge metrics "fixture" "backlog"
        samplePackGaugeWith (pure (Right Nothing)) record (\_ _ -> assertFailure "an absent level is not a failure")
        void (Metric.forceFlushMeterProvider provider Nothing)
        batches <- readIORef exported
        assertBool "no level, no gauge point" (null [point | batch <- batches, scope <- Vector.toList batch.resourceMetricsScopes, MetricExportGauge {megGaugePoints = points} <- Vector.toList scope.scopeMetricsExports, point <- Vector.toList points])
        samplePackGaugeWith (pure (Right (Just 7))) record (\_ _ -> assertFailure "a level is not a failure")
        void (Metric.forceFlushMeterProvider provider Nothing)
        gauge <- assertMetricNamed exported "shikigami.pack.gauges"
        case gauge of
          MetricExportGauge {megGaugePoints = points} -> do
            map (.gaugeDataPointValue) (Vector.toList points) @?= [IntNumber 7]
            map (show . (.gaugeDataPointAttributes)) (Vector.toList points) @?= [show (attrs [("pack", "fixture"), ("gauge", "backlog")])]
          _ -> assertFailure "expected a gauge"
        void (Metric.shutdownMeterProvider provider Nothing),
      testCase "a failed pack gauge read is reported, records nothing and leaves other instruments exported" do
        failures <- newIORef []
        (exporter, exported) <- inMemoryMetricExporter
        (provider, _) <- Metric.createMeterProvider emptyMaterializedResources Metric.defaultSdkMeterProviderOptions {Metric.metricExporter = Just exporter}
        meter <- Metric.getMeter provider shikigamiInstrumentationLibrary
        metrics <- newShikigamiMetrics meter
        samplePackGaugeWith (pure (Left "ledger unavailable")) (recordPackGauge metrics "fixture" "backlog") (\target _ -> modifyIORef' failures (target :))
        recordQueueDepth metrics 2
        void (Metric.forceFlushMeterProvider provider Nothing)
        void (assertMetricNamed exported "shikigami.queue.depth")
        readIORef failures >>= (@?= [PackGaugeSample])
        void (Metric.shutdownMeterProvider provider Nothing),
      testCase "sampler failure does not suppress the independent sample" do
        outboxCalls <- newIORef (0 :: Int)
        failures <- newIORef []
        depths <- newIORef []
        sampleTelemetryWith
          (pure (Left "queue unavailable"))
          (modifyIORef' outboxCalls (+ 1) >> pure (Right ()))
          (\depth -> modifyIORef' depths (depth :))
          (\target detail -> modifyIORef' failures ((target, detail) :))
        readIORef outboxCalls >>= assertEqual "outbox sampler still ran" 1
        readIORef depths >>= assertEqual "failed queue did not record a depth" []
        readIORef failures >>= assertEqual "queue failure was reported" [(QueueSample, "queue unavailable")]
    ]

attrs :: [(Data.Text.Text, Data.Text.Text)] -> Attributes
attrs = addAttributesFromBuilder defaultAttributeLimits emptyAttributes . foldMap (uncurry attr)
