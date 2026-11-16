module Shikigami.TelemetrySpec (tests) where

import Control.Monad (void)
import Data.Aeson (eitherDecode)
import Data.Foldable (traverse_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified
import Data.Time (getCurrentTime)
import Data.Vector qualified as Vector
import Keiro.Workflow (WorkflowId (..), WorkflowName (..))
import OpenTelemetry.Attributes (Attributes, addAttributesFromBuilder, attr, defaultAttributeLimits, emptyAttributes)
import OpenTelemetry.Exporter.InMemory
  ( assertMetricNamed,
    inMemoryMetricExporter,
  )
import OpenTelemetry.Exporter.Metric
import OpenTelemetry.Metric qualified as Metric
import OpenTelemetry.Resource (emptyMaterializedResources)
import Shikigami.Flow.Observe (ObserveHooks (..))
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.StateRevision (initialRevision)
import Shikigami.Telemetry.Metrics
  ( newShikigamiMetrics,
    recordConsumerRecord,
    recordPackEvent,
    recordQueueDepth,
    recordRunCompleted,
    recordRunDeadLettered,
    recordRunFailed,
    recordRunRetried,
    recordRunStarted,
    recordStreamDisposition,
    recordWatchdogAge,
    shikigamiInstrumentationLibrary,
  )
import Shikigami.Telemetry.Sampler (SampleTarget (QueueSample, WatchdogSample), sampleTelemetryWith, sampleWatchdogAge, sampleWatchdogWith, watchdogHooks)
import Shikigami.Watchdog.Grant
import Shikigami.Watchdog.Ledger (SweepOrigin (..), SweepSummary (..))
import Shikigami.Watchdog.Observation (PassCompletion (PassCompleted))
import Shikigami.Watchdog.Store qualified as Ledger
import Shikigami.Watchdog.Types
import Shikigami.WorkerSession.Input (workerSessionId)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
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
            "shikigami.pack.events"
          ]
        void (Metric.shutdownMeterProvider provider Nothing)
    ]

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

attrs :: Data.Text.Text -> Data.Text.Text -> Attributes
attrs key value = addAttributesFromBuilder defaultAttributeLimits emptyAttributes (attr key value)
