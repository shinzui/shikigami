-- | Shared startup work before listeners or workflow workers can serve data.
module Shikigami.Runtime (registerRuntimeCatalog, runtimeConnectionSettings) where

import Control.Lens ((&), (.~))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Pool.Observation qualified as Pool
import Keiro.Telemetry (KeiroMetrics, kirokuEventBridge)
import Kiroku.Store.Connection (ConnectionSettings, KirokuStore, defaultConnectionSettings)
import Kiroku.Store.Effect (runStorePool)
import Kiroku.Store.Error (StoreError)
import Shikigami.Log qualified as Log
import Shikigami.RunEvidence.Catalog qualified as Evidence
import Shikigami.RunEvidence.Generated.EventStream (runEvidenceEventStream)

-- | Register the validated query and projection catalog using the acquired
-- runtime store. Registration failure refuses startup; this never rebuilds or
-- deletes live-only evidence tables.
registerRuntimeCatalog :: KirokuStore -> IO ()
registerRuntimeCatalog store = do
  result <-
    runEff . runErrorNoCallStack @StoreError . runStorePool store $
      runEvidenceEventStream `seq`
        Evidence.registerProjectionCatalog
  case result of
    Right (Right _) -> pure ()
    failure -> ioError (userError ("runtime catalog registration failed: " <> show failure))

-- | Extend upstream defaults only after process telemetry exists. Callback
-- fields are bounded classifications; connection strings and database errors
-- (which may contain credentials or payloads) never enter these log fields.
runtimeConnectionSettings :: Log.Logger -> Maybe KeiroMetrics -> Text -> ConnectionSettings
runtimeConnectionSettings logger metrics connectionString =
  defaultConnectionSettings connectionString
    & #eventHandler
      .~ Just
        ( kirokuEventBridge metrics \event ->
            Log.logDebug logger "store.event" ["kind" Aeson..= Text.takeWhile (/= ' ') (Text.pack (show event))]
        )
    & #observationHandler
      .~ Just
        ( \(Pool.ConnectionObservation _ status) ->
            Log.logDebug logger "store.pool" ["status" Aeson..= poolStatus status]
        )
  where
    poolStatus :: Pool.ConnectionStatus -> Text
    poolStatus = \case
      Pool.ConnectingConnectionStatus -> "connecting"
      Pool.ReadyForUseConnectionStatus _ -> "ready"
      Pool.InUseConnectionStatus -> "in_use"
      Pool.TerminatedConnectionStatus _ -> "terminated"
