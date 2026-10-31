-- | Durable inspection in the server; consumer-local metrics stay in workers.
module Shikigami.Inspection.Server (withServerInspection) where

import Kiroku.Metrics (KirokuMetrics)
import Kiroku.Store.Connection (ConnectionSettings, KirokuStore)
import Shikigami.App.Config (AppConfig (..))
import Shikigami.Inspection.Runtime (withInspectionRuntime)
import Shikigami.Log qualified as Log

withServerInspection :: AppConfig -> Log.Logger -> ConnectionSettings -> KirokuStore -> KirokuMetrics -> IO a -> IO a
withServerInspection config logger settings store metrics action =
  withInspectionRuntime config.inspection logger settings store metrics [] (const action)
