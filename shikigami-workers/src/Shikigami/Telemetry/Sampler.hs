-- | Periodic point-in-time metrics for durable worker backlogs.
module Shikigami.Telemetry.Sampler
  ( runTelemetrySampler,
    sampleTelemetryOnce,
    SampleTarget (..),
    sampleTelemetryWith,
    sampleWatchdogWith,
    sampleWatchdogAge,
    watchdogHooks,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Pool qualified as Pool
import Keiro.Outbox (sampleOutboxBacklog)
import Kiroku.Store.Transaction (runTransactionNoRetry)
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Hasql.Statements.Types (QueueMetrics (..))
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Flow.Observe (ObserveHooks (..), ObserveSeed (..))
import Shikigami.Health.Worker (LoopName (TelemetryLoop), beat)
import Shikigami.Log qualified as Log
import Shikigami.Telemetry.Metrics (ShikigamiMetrics, recordQueueDepth, recordWatchdogAge, recordWatchdogFinding, recordWatchdogRefusal, recordWatchdogSweep)
import Shikigami.Trigger.Enqueue (runQueueName)
import Shikigami.Watchdog.Ledger (SweepSummary (..))
import Shikigami.Watchdog.Settings (WatchdogSettings (..))
import Shikigami.Watchdog.Store (readSweepAgeSeconds)
import Shikigami.Watchdog.Types (DetectionKind (..), FindingView (..))
import Shikigami.Workers.Config
  ( WorkerEnv (..),
    envHeartbeats,
    envKeiroMetrics,
    envLogger,
    envMetrics,
  )

data SampleTarget = QueueSample | OutboxSample | WatchdogSample
  deriving stock (Eq, Show)

-- | Sample immediately, then every fifteen seconds. A dependency error is an
-- observability gap, not a reason to stop processing durable work.
runTelemetrySampler :: WorkerEnv -> IO ()
runTelemetrySampler env = forever do
  sampleTelemetryOnce env
  beat (envHeartbeats env) TelemetryLoop
  threadDelay 15_000_000

sampleTelemetryOnce :: WorkerEnv -> IO ()
sampleTelemetryOnce env = do
  sampleTelemetryWith
    (first (Text.pack . show) . fmap queueLength <$> Pool.use ((.pool) env) (Pgmq.queueMetrics runQueueName))
    (first (Text.pack . show) <$> runAppIO ((.appEnv) env) (sampleOutboxBacklog (envKeiroMetrics env)))
    (recordQueueDepth (envMetrics env))
    logFailure
  sampleWatchdogWith (sampleWatchdogAge env.appEnv env.observe.settings) (recordWatchdogAge (envMetrics env)) logFailure
  where
    logFailure target err =
      Log.logWarn
        (envLogger env)
        (sampleFailureEvent target)
        ["error" .= err]

    sampleFailureEvent = \case
      QueueSample -> "worker.metrics.queue_sample_failed"
      OutboxSample -> "worker.metrics.outbox_sample_failed"
      WatchdogSample -> "worker.metrics.watchdog_sample_failed"

-- | Run both samplers independently. A failure in either branch is reported
-- and swallowed, and never prevents the other branch from sampling.
sampleTelemetryWith :: IO (Either Text Int64) -> IO (Either Text ()) -> (Int64 -> IO ()) -> (SampleTarget -> Text -> IO ()) -> IO ()
sampleTelemetryWith sampleQueue sampleOutbox recordDepth reportFailure = do
  sampleQueue >>= either (reportFailure QueueSample) recordDepth
  sampleOutbox >>= either (reportFailure OutboxSample) pure

-- | Optional age is unavailable until a completion exists. A failed read is
-- isolated from the other samplers and never paints a fresh zero.
sampleWatchdogWith :: IO (Either Text (Maybe Int64)) -> (Int64 -> IO ()) -> (SampleTarget -> Text -> IO ()) -> IO ()
sampleWatchdogWith sample record report = sample >>= either (report WatchdogSample) (mapM_ record)

sampleWatchdogAge :: AppEnv -> Maybe WatchdogSettings -> IO (Either Text (Maybe Int64))
sampleWatchdogAge _ Nothing = pure (Right Nothing)
sampleWatchdogAge env (Just settings) = do
  result <- runAppIO env (runTransactionNoRetry (readSweepAgeSeconds settings.principal settings.scope))
  pure case result of
    Right (Right age) -> Right age
    _ -> Left "watchdog ledger unavailable"

-- | Fixed tags only. Counters describe runtime callbacks (at least once around
-- a lost journal append); the retained ledger is the audit authority.
watchdogHooks :: ShikigamiMetrics -> ObserveHooks
watchdogHooks metrics =
  ObserveHooks
    { onSweepCompleted = \_ summary -> do
        recordWatchdogSweep metrics (if summary.refusals == 0 then "completed" else "refused")
        if summary.refusals == 0 then pure () else recordWatchdogRefusal metrics "retained" (fromIntegral summary.refusals),
      onFinding = \finding -> recordWatchdogFinding metrics (case finding.kind of StuckWork -> "stuck"; UnresolvedOutcome -> "unresolved"; StuckCoordinatorWork -> "stuck-coordinator"; DriftWork -> "drift"),
      onRefusal = recordWatchdogSweep metrics "refused" >> recordWatchdogRefusal metrics "uncompleted" 1,
      onSweepFailed = recordWatchdogSweep metrics "failed"
    }
