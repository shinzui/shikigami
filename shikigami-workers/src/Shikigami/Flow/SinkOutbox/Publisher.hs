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
    publishTrackerRow,
    reconcilePublishedRow,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forever, when)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Effectful (Eff)
import Effectful.Dispatch.Static (unsafeEff_)
import Keiro.Integration.Event (IntegrationEvent (..), decodeJsonIntegrationEvent)
import Keiro.Outbox (OutboxPublishSummary (..), PublishOutcome (PublishFailed, PublishSucceeded), defaultPublishOptions, publishClaimedOutbox)
import Keiro.Outbox.Types (OutboxRow (..))
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.App (runAppIO)
import Shikigami.Health.Worker (LoopName (OutboxLoop), beat)
import Shikigami.Log qualified as Log
import Shikigami.Objective.Store (ObjectiveEffects)
import Shikigami.Objective.Tracker.Dispatch qualified as TrackerDispatch
import Shikigami.Objective.Tracker.Publication (trackerDestination)
import Shikigami.Objective.Tracker.Store qualified as Tracker
import Shikigami.Objective.Tracker.Types
import Shikigami.Workers.Config (WorkerEnv (..), agentRunDeps, envHeartbeats, envKeiroMetrics, envLogger)

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
    attempted <- newIORef []
    -- The released Keiro publisher hands the publisher a whole claimed batch and expects one
    -- outcome per row, so the single-row dispatcher is lifted rather than
    -- rewritten: the batch semantics (ordering policy, marking) stay Keiro's.
    let publishBatch rows = do
          outcomes <-
            traverse
              ( \row -> do
                  outcome <- publishTrackerRow env.trackers (AgentWorkflow.publishSinkIntent deps) row
                  unsafeEff_ (beat (envHeartbeats env) OutboxLoop)
                  pure (outboxId row, outcome)
              )
              rows
          unsafeEff_ (modifyIORef' attempted (<> zip rows (snd <$> outcomes)))
          pure outcomes
    result <- runAppIO ((.appEnv) env) (publishClaimedOutbox publishBatch defaultPublishOptions (envKeiroMetrics env))
    case result of
      Left err -> Log.logError (envLogger env) "worker.outbox.failed" ["error" .= Text.pack (show err)]
      Right summary -> do
        logPublishSummary (envLogger env) summary
        outcomes <- readIORef attempted
        traverse_
          ( \(row, outcome) -> case outcome of
              PublishSucceeded -> reconcilePublishedRow (AgentWorkflow.reconcilePublishedSinkIntent deps) row
              _ -> pure ()
          )
          outcomes
    -- Beat on every pass, including a failed one: a store error is a dependency
    -- being unavailable, not this loop being wedged, and the loop is
    -- demonstrably still going round. Beating only on success would restart the
    -- process for a database outage that readiness already reports.
    beat (envHeartbeats env) OutboxLoop
    threadDelay 1_000_000

-- | Report only passes that claimed work, so an idle one-second polling loop
-- does not fill the log. A dead-lettered or permanently rejected row is an
-- error, a retry is a warning, and a wholly successful pass is informational.
logPublishSummary :: Log.Logger -> OutboxPublishSummary -> IO ()
logPublishSummary logger OutboxPublishSummary {claimed, published, rejected, retried, dead} =
  when (claimed > 0) do
    let fields =
          [ "claimed" .= claimed,
            "published" .= published,
            "rejected" .= rejected,
            "retried" .= retried,
            "dead" .= dead
          ]
    if dead > 0
      then Log.logError logger "worker.outbox.dead_lettered" fields
      else
        if rejected > 0
          then Log.logError logger "worker.outbox.rejected" fields
          else
            if retried > 0
              then Log.logWarn logger "worker.outbox.retried" fields
              else Log.logInfo logger "worker.outbox.published" fields

-- Routing is shared by the publish and post-success callbacks. Quarantine is
-- transport success only: the domain receipt remains Unknown and queryable.
publishTrackerRow :: (ObjectiveEffects es) => Maybe Tracker.TrackerHost -> (OutboxRow -> Eff es PublishOutcome) -> OutboxRow -> Eff es PublishOutcome
publishTrackerRow configured legacy row
  | row.event.destination /= trackerDestination = legacy row
  | otherwise = case (configured, decodeJsonIntegrationEvent row.event) of
      (Just host, Right (wire :: PublicationDispatch))
        | wire.version == TrackerV1,
          row.event.source == "shinzui/shikigami",
          row.event.eventType == "shikigami.objective-tracker.publication-requested",
          row.event.schemaVersion == 1,
          row.event.messageId == "objective-tracker:" <> coordinateText wire.publicationId,
          row.event.key == Just (coordinateText wire.bindingId) -> do
            retained <- TrackerDispatch.lookupPublication host wire.objectiveId wire.publicationId
            case retained of
              Right (intent, _) | intent.bindingId == wire.bindingId -> do
                dispatched <- TrackerDispatch.dispatch host wire.objectiveId wire.publicationId
                pure case dispatched of
                  Right TrackerDispatch.Settled -> PublishSucceeded
                  Right TrackerDispatch.Quarantined -> PublishSucceeded
                  _ -> PublishFailed "objective tracker dispatch deferred"
              _ -> pure (PublishFailed "objective tracker publication unavailable")
      _ -> pure (PublishFailed "objective tracker route unavailable or invalid")

reconcilePublishedRow :: (Applicative f) => (OutboxRow -> f ()) -> OutboxRow -> f ()
reconcilePublishedRow legacy row
  | row.event.destination == trackerDestination = pure () -- Domain receipt committed before transport acknowledgement.
  | otherwise = legacy row
