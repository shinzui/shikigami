-- | Shared startup work before listeners or workflow workers can serve data.
module Shikigami.Runtime (registerRuntimeCatalog) where

import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect (runStorePool)
import Kiroku.Store.Error (StoreError)
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
