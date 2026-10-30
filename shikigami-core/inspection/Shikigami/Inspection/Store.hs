-- | Compose every callback claimant before acquiring the serving store.
module Shikigami.Inspection.Store (withObservedStore) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Data.IntMap.Strict qualified as IntMap
import Kiroku.Metrics qualified as Metrics
import Kiroku.Otel.Subscription (subscriptionTraceHandler)
import Kiroku.Otel.TraceContext (injectTraceContext)
import Kiroku.Store.Connection (ConnectionSettings, ConnectionSettingsM (..), KirokuStore (..), withStore)
import Kiroku.Store.Settings (StoreSettings (..))
import Kiroku.Store.Subscription.EventPublisher (EventPublisher (..), publisherPosition)
import Kiroku.Store.Types (GlobalPosition (..))
import OpenTelemetry.Trace.Core qualified as Trace

-- Gauges cannot be queried by a listener until the acquired store is installed.
-- The collector, traces and existing Keiro/log passthroughs all exist before
-- acquisition. Their callbacks perform bounded in-memory work; export is batched
-- by the process telemetry owner. No subscription is created for inspection.
withObservedStore :: Trace.Tracer -> ConnectionSettings -> (KirokuStore -> Metrics.KirokuMetrics -> IO a) -> IO a
withObservedStore tracer settings action = do
  live <- newTVarIO Nothing
  collector <-
    Metrics.newKirokuMetricsWith
      (readTVar live >>= maybe (pure (GlobalPosition 0)) (publisherPosition . (.publisher)))
      (readTVar live >>= maybe (pure 0) (fmap IntMap.size . readTVar . (.subscribers) . (.publisher)))
  traceEvents <- subscriptionTraceHandler tracer
  let passthrough event = traceEvents event >> maybe (pure ()) ($ event) settings.eventHandler
      enrich event = do
        original <- maybe (pure event) ($ event) settings.storeSettings.enrichEvent
        context <- Trace.getActiveSpan >>= traverse Trace.getSpanContext
        pure $ case context of
          Just current | Trace.isValid current -> injectTraceContext current original
          _ -> original
      observed =
        settings
          { eventHandler = Just (Metrics.metricsEventHandler collector (Just passthrough)),
            observationHandler = Just (Metrics.metricsObservationHandler collector settings.observationHandler),
            storeSettings = settings.storeSettings {enrichEvent = Just enrich}
          }
  withStore observed \store -> do
    atomically (writeTVar live (Just store))
    action store collector
