-- | Periodic point-in-time metrics for durable worker backlogs.
module Shikigami.Telemetry.Sampler
  ( runTelemetrySampler,
    sampleTelemetryOnce,
    SampleTarget (..),
    sampleTelemetryWith,
    samplePackGaugeWith,
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
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Hasql.Statements.Types (QueueMetrics (..))
import Shikigami.App (runAppIO)
import Shikigami.Flow.Pack (PackGauge (..), flowPackNameText, registeredGauges)
import Shikigami.Health.Worker (LoopName (TelemetryLoop), beat)
import Shikigami.Log qualified as Log
import Shikigami.Telemetry.Metrics (recordPackGauge, recordQueueDepth)
import Shikigami.Trigger.Enqueue (runQueueName)
import Shikigami.Workers.Config
  ( WorkerEnv (..),
    envHeartbeats,
    envKeiroMetrics,
    envLogger,
    envMetrics,
  )

data SampleTarget = QueueSample | OutboxSample | PackGaugeSample
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
  -- Each composed pack's gauges, one read apiece. A pack names the gauge; the
  -- kernel names nothing a pack measures.
  mapM_
    ( \(pack, gauge) ->
        samplePackGaugeWith
          (either (const (Left "store unavailable")) id <$> runAppIO env.appEnv (gauge.sample env.packSettings))
          (recordPackGauge (envMetrics env) (flowPackNameText pack) gauge.name)
          (\target err -> Log.logWarn (envLogger env) (sampleFailureEvent target) ["pack" .= flowPackNameText pack, "gauge" .= gauge.name, "error" .= err])
    )
    (registeredGauges env.flows)
  where
    logFailure target err =
      Log.logWarn
        (envLogger env)
        (sampleFailureEvent target)
        ["error" .= err]

    sampleFailureEvent = \case
      QueueSample -> "worker.metrics.queue_sample_failed"
      OutboxSample -> "worker.metrics.outbox_sample_failed"
      PackGaugeSample -> "worker.metrics.pack_gauge_sample_failed"

-- | Run both samplers independently. A failure in either branch is reported
-- and swallowed, and never prevents the other branch from sampling.
sampleTelemetryWith :: IO (Either Text Int64) -> IO (Either Text ()) -> (Int64 -> IO ()) -> (SampleTarget -> Text -> IO ()) -> IO ()
sampleTelemetryWith sampleQueue sampleOutbox recordDepth reportFailure = do
  sampleQueue >>= either (reportFailure QueueSample) recordDepth
  sampleOutbox >>= either (reportFailure OutboxSample) pure

-- | A level is unavailable until the pack has one. A failed read is isolated
-- from the other samplers and never paints a fresh zero.
samplePackGaugeWith :: IO (Either Text (Maybe Int64)) -> (Int64 -> IO ()) -> (SampleTarget -> Text -> IO ()) -> IO ()
samplePackGaugeWith sample record report = sample >>= either (report PackGaugeSample) (mapM_ record)
