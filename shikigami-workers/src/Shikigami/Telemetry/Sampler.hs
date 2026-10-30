-- | Periodic point-in-time metrics for durable worker backlogs.
module Shikigami.Telemetry.Sampler
  ( runTelemetrySampler,
    sampleTelemetryOnce,
    SampleTarget (..),
    sampleTelemetryWith,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
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
import Shikigami.Health.Worker (LoopName (TelemetryLoop), beat)
import Shikigami.Log qualified as Log
import Shikigami.Telemetry.Metrics (recordQueueDepth)
import Shikigami.Trigger.Enqueue (runQueueName)
import Shikigami.Workers.Config
  ( WorkerEnv (..),
    envHeartbeats,
    envKeiroMetrics,
    envLogger,
    envMetrics,
  )

data SampleTarget = QueueSample | OutboxSample
  deriving stock (Eq, Show)

-- | Sample immediately, then every fifteen seconds. A dependency error is an
-- observability gap, not a reason to stop processing durable work.
runTelemetrySampler :: WorkerEnv -> IO ()
runTelemetrySampler env = forever do
  sampleTelemetryOnce env
  beat (envHeartbeats env) TelemetryLoop
  threadDelay 15_000_000

sampleTelemetryOnce :: WorkerEnv -> IO ()
sampleTelemetryOnce env =
  sampleTelemetryWith
    (first (Text.pack . show) . fmap queueLength <$> Pool.use ((.pool) env) (Pgmq.queueMetrics runQueueName))
    (first (Text.pack . show) <$> runAppIO ((.appEnv) env) (sampleOutboxBacklog (envKeiroMetrics env)))
    (recordQueueDepth (envMetrics env))
    logFailure
  where
    logFailure target err =
      Log.logWarn
        (envLogger env)
        (sampleFailureEvent target)
        ["error" Aeson..= err]

    sampleFailureEvent = \case
      QueueSample -> "worker.metrics.queue_sample_failed"
      OutboxSample -> "worker.metrics.outbox_sample_failed"

-- | Run both samplers independently. A failure in either branch is reported
-- and swallowed, and never prevents the other branch from sampling.
sampleTelemetryWith :: IO (Either Text Int64) -> IO (Either Text ()) -> (Int64 -> IO ()) -> (SampleTarget -> Text -> IO ()) -> IO ()
sampleTelemetryWith sampleQueue sampleOutbox recordDepth reportFailure = do
  sampleQueue >>= either (reportFailure QueueSample) recordDepth
  sampleOutbox >>= either (reportFailure OutboxSample) pure
