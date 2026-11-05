module Shikigami.TelemetrySpec (tests) where

import Control.Monad (void)
import Data.Foldable (traverse_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import OpenTelemetry.Exporter.InMemory
  ( assertMetricNamed,
    inMemoryMetricExporter,
  )
import OpenTelemetry.Metric qualified as Metric
import OpenTelemetry.Resource (emptyMaterializedResources)
import Shikigami.Telemetry.Metrics
  ( newShikigamiMetrics,
    recordConsumerRecord,
    recordInitiativeAdmission,
    recordInitiativeCandidate,
    recordInitiativeProposal,
    recordInitiativeRefusal,
    recordQueueDepth,
    recordRunCompleted,
    recordRunDeadLettered,
    recordRunFailed,
    recordRunRetried,
    recordRunStarted,
    shikigamiInstrumentationLibrary,
  )
import Shikigami.Telemetry.Sampler (SampleTarget (QueueSample), sampleTelemetryWith)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
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
        recordInitiativeCandidate metrics "skipped" (Just "excerpt-too-short")
        recordInitiativeProposal metrics "pending"
        recordInitiativeAdmission metrics "launched"
        recordInitiativeRefusal metrics "evaluations-exhausted"

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
            "shikigami.initiatives.candidates",
            "shikigami.initiatives.proposals",
            "shikigami.initiatives.admissions",
            "shikigami.initiatives.refusals"
          ]
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
