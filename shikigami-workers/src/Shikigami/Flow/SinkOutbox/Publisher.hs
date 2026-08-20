-- | Publishing the sink outbox.
--
-- An agent run does not call kizashi, kawa, danwa, or rei while its durable
-- workflow is executing. It records the intent to call them in an /outbox/ table
-- inside the same database transaction that records the run, and this loop
-- delivers those rows afterwards. That is what makes a crash between \"the run
-- happened\" and \"the sink was called\" impossible: either both are in the
-- transaction or neither is.
--
-- The loop claims a batch of unpublished rows, hands each to the sink dispatcher,
-- and sleeps a second before looking again. Retry ceilings, dead-lettering, and
-- delivery accounting for the rows it cannot deliver are owned by
-- @docs\/plans\/19-sink-delivery-truth-and-downstream-idempotency.md@; this loop
-- uses whatever @publishClaimedOutbox@ already does and adds no policy of its own.
module Shikigami.Flow.SinkOutbox.Publisher
  ( runOutboxPublisher,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Keiro.Outbox (defaultPublishOptions, publishClaimedOutbox)
import Keiro.Outbox.Types (OutboxRow (..))
import Kioku.App (runAppIO)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Health.Worker (LoopName (OutboxLoop), beat)
import Shikigami.Log qualified as Log
import Shikigami.Workers.Config (WorkerEnv (..), agentRunDeps, envHeartbeats, envLogger)

-- | Publish claimed outbox rows until the process stops.
--
-- A store error is logged and the loop continues: the rows are still in the
-- table, so the next pass retries them. Exiting instead would strand every
-- pending sink delivery behind one transient database failure.
runOutboxPublisher :: WorkerEnv -> IO ()
runOutboxPublisher env = do
  Log.logInfo (envLogger env) "worker.outbox.started" []
  forever do
    let deps = agentRunDeps env
    -- Keiro 0.4 hands the publisher a whole claimed batch and expects one
    -- outcome per row, so the single-row dispatcher is lifted rather than
    -- rewritten: the batch semantics (ordering policy, marking) stay Keiro's.
    let publishBatch rows =
          traverse
            (\row -> (outboxId row,) <$> AgentWorkflow.publishSinkIntent deps row)
            rows
    result <- runAppIO (appEnv env) (publishClaimedOutbox publishBatch defaultPublishOptions Nothing)
    case result of
      Left err -> Log.logError (envLogger env) "worker.outbox.failed" ["error" Aeson..= Text.pack (show err)]
      Right _summary -> pure ()
    -- Beat on every pass, including a failed one: a store error is a dependency
    -- being unavailable, not this loop being wedged, and the loop is
    -- demonstrably still going round. Beating only on success would restart the
    -- process for a database outage that readiness already reports.
    beat (envHeartbeats env) OutboxLoop
    threadDelay 1_000_000
