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
import Shikigami.Fixture.Proposing qualified as P
import Shikigami.Flow.Observe (ObserveHooks (..))
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.StateRevision (initialRevision)
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
      testCase "ledger age exports without a watchdog run and hooks use bounded tags" $ P.withProposing fixture P.defaultOptions \h -> do
        configured <- right (eitherDecode "{\"principal\":\"agent_watchdog\",\"scope\":\"all\",\"stuckWindowSeconds\":60,\"parkedWindowSeconds\":30,\"coordinatorWindowSeconds\":60,\"subjectsPerSweep\":9}")
        grant <- right (resolveObservationGrant (Just configured) configured.principal)
        (exporter, exported) <- inMemoryMetricExporter
        (provider, _) <- Metric.createMeterProvider emptyMaterializedResources Metric.defaultSdkMeterProviderOptions {Metric.metricExporter = Just exporter}
        meter <- Metric.getMeter provider shikigamiInstrumentationLibrary
        metrics <- newShikigamiMetrics meter
        sampleWatchdogWith (sampleWatchdogAge h.env (Just configured)) (recordWatchdogAge metrics) (\_ _ -> assertFailure "empty ledger failed")
        void (Metric.forceFlushMeterProvider provider Nothing)
        batches <- readIORef exported
        assertBool "empty ledger has no gauge point" (null [point | batch <- batches, scope <- Vector.toList batch.resourceMetricsScopes, MetricExportGauge {megGaugePoints = points} <- Vector.toList scope.scopeMetricsExports, point <- Vector.toList points])
        now <- getCurrentTime
        sweep <- newSweepId
        _ <- P.runTx h (Ledger.openSweep sweep (SweepOrigin (WorkflowName "telemetry-fixture") (WorkflowId "ledger-only") now configured.principal) (snapshotGrant grant)) >>= right
        let summary = SweepSummary now 0 1 0 PassCompleted
        _ <- P.runTx h (Ledger.closeSweep sweep summary) >>= right
        sampleWatchdogWith (sampleWatchdogAge h.env (Just configured)) (recordWatchdogAge metrics) (\_ _ -> assertFailure "completed ledger failed")
        let hooks = watchdogHooks metrics
        hooks.onSweepCompleted sweep summary
        hooks.onSweepCompleted sweep (SweepSummary now 1 0 0 PassCompleted)
        episode <- newEpisodeId
        finding <- newFindingId
        budget <- right (parseWatchdogLimit 9)
        let subject = workerSessionId "metric-subject"
        hooks.onFinding (FindingView finding episode sweep Nothing (WorkerSession subject) StuckWork (SessionEvidence subject initialRevision :| []) (ObservedWindow now now now) (ObservationLimit budget Complete Complete))
        hooks.onRefusal
        hooks.onSweepFailed
        void (Metric.forceFlushMeterProvider provider Nothing)
        gauge <- assertMetricNamed exported "shikigami.watchdog.sweep.age"
        case gauge of
          MetricExportGauge {megGaugePoints = points} -> do
            assertBool "DB age nonnegative" (any (\point -> case point.gaugeDataPointValue of IntNumber value -> value >= 0; _ -> False) points)
            map (.gaugeDataPointAttributes) (Vector.toList points) @?= [emptyAttributes]
          _ -> assertFailure "expected gauge"
        sweeps <- assertMetricNamed exported "shikigami.watchdog.sweeps"
        assertBool "closed outcomes, no identifiers" (not (null (show sweeps)) && not (show sweep `isInfixOf` show sweeps))
        case sweeps of
          MetricExportSum {mesSumPoints = points} -> sort (map (show . (.sumDataPointAttributes)) (Vector.toList points)) @?= sort (map show [attrs "outcome" "refused", attrs "outcome" "failed", attrs "outcome" "completed"])
          _ -> assertFailure "expected sweep counter"
        findings <- assertMetricNamed exported "shikigami.watchdog.findings"
        case findings of
          MetricExportSum {mesSumPoints = points} -> map (.sumDataPointAttributes) (Vector.toList points) @?= [attrs "detection.kind" "stuck"]
          _ -> assertFailure "expected finding counter"
        refusals <- assertMetricNamed exported "shikigami.watchdog.refusals"
        case refusals of
          MetricExportSum {mesSumPoints = points} -> sort (map (show . (.sumDataPointAttributes)) (Vector.toList points)) @?= sort (map show [attrs "refusal.kind" "retained", attrs "refusal.kind" "uncompleted"])
          _ -> assertFailure "expected refusal counter"
        void (Metric.shutdownMeterProvider provider Nothing),
      testCase "failed watchdog read leaves other instruments exported" do
        failures <- newIORef []
        (exporter, exported) <- inMemoryMetricExporter
        (provider, _) <- Metric.createMeterProvider emptyMaterializedResources Metric.defaultSdkMeterProviderOptions {Metric.metricExporter = Just exporter}
        meter <- Metric.getMeter provider shikigamiInstrumentationLibrary
        metrics <- newShikigamiMetrics meter
        sampleWatchdogWith (pure (Left "ledger unavailable")) (recordWatchdogAge metrics) (\target _ -> modifyIORef' failures (target :))
        recordQueueDepth metrics 2
        void (Metric.forceFlushMeterProvider provider Nothing)
        void (assertMetricNamed exported "shikigami.queue.depth")
        readIORef failures >>= (@?= [WatchdogSample])
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

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

attrs :: Data.Text.Text -> Data.Text.Text -> Attributes
attrs key value = addAttributesFromBuilder defaultAttributeLimits emptyAttributes (attr key value)
