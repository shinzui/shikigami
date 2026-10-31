-- | Inspect the actual consumer master for exactly its owned lifetime.
module Shikigami.Inspection.Consumer
  ( ConsumerInspection (..),
    consumerInspection,
    withConsumerInspection,
  )
where

import Control.Exception (bracket)
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, Limit (Limited), Persistence (Persistent), UnliftStrategy (ConcUnlift), withEffToIO, (:>))
import Keiro.Ops.Http (MountedSurface (..), shibuyaPrefix)
import Kiroku.Metrics (KirokuMetrics)
import Kiroku.Store.Connection (ConnectionSettings, KirokuStore)
import Shibuya.App (Master)
import Shibuya.Metrics.Config qualified as Metrics
import Shibuya.Metrics.Server (combinedApp)
import Shibuya.Metrics.WebSocket (newWebSocketState, shutdownWebSockets)
import Shikigami.Inspection.Runtime (withInspectionRuntime)
import Shikigami.Inspection.Settings (InspectionSettings (..))
import Shikigami.Log qualified as Log

newtype ConsumerInspection = ConsumerInspection
  { run :: forall a. Master -> IO a -> IO a
  }

consumerInspection :: NominalDiffTime -> Maybe InspectionSettings -> Log.Logger -> ConnectionSettings -> KirokuStore -> KirokuMetrics -> ConsumerInspection
consumerInspection _ Nothing _ _ _ _ = ConsumerInspection (\_ action -> action)
consumerInspection staleAfter settings@(Just selected) logger connection store metrics = ConsumerInspection \master action -> do
  let config =
        Metrics.defaultConfig
          { Metrics.wsMaxConnections = selected.maxConnections,
            Metrics.wsMaxSubscriptions = selected.maxViews,
            Metrics.wsMaxQueuedFrames = selected.maxQueuedFrames,
            Metrics.wsMaxQueuedBytes = selected.maxQueuedBytes,
            Metrics.wsSendTimeoutUs = selected.deliveryDeadlineSeconds * 1000000,
            Metrics.wsPushIntervalUs = selected.refreshMillis * 1000,
            Metrics.corsAllowedOrigins = selected.allowedOrigins,
            Metrics.stuckThreshold = staleAfter
          }
  -- Control remains disabled; enabling Keiro mutations grants no processor
  -- pause authority. No second Shibuya app, adapter or consumer is allocated.
  bracket (newWebSocketState selected.maxConnections) shutdownWebSockets \state ->
    withInspectionRuntime settings logger connection store metrics [MountedSurface shibuyaPrefix (combinedApp config master state [])] (const action)

withConsumerInspection :: (IOE :> es) => ConsumerInspection -> Master -> Eff es a -> Eff es a
withConsumerInspection ConsumerInspection {run} master action =
  withEffToIO (ConcUnlift Persistent (Limited 1)) \runInIO -> run master (runInIO action)
