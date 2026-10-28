-- | Hand-owned bridge to the live evidence boundary. Never reconstruct rich
-- payloads from lifecycle history or accept an unbound application callback.
module Shikigami.ProjectionCatalog.ProjectionCatalogHoles (applyRunEvidenceWriterLive, applyExecutionWriterLive) where

import Control.Exception (throw)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Types (RecordedEvent)
import Shikigami.Execution.Live (MissingLiveExecution (..))
import Shikigami.ExecutionLifecycle.Generated.Domain (ExecutionLifecycleEvent)
import Shikigami.RunEvidence.Generated.Domain (RunEvidenceEvent)
import Shikigami.RunEvidence.Live (requireLiveEvidence)

applyRunEvidenceWriterLive :: RunEvidenceEvent -> RecordedEvent -> Tx.Transaction ()
applyRunEvidenceWriterLive = requireLiveEvidence

applyExecutionWriterLive :: ExecutionLifecycleEvent -> RecordedEvent -> Tx.Transaction ()
applyExecutionWriterLive _ _ = throw MissingLiveExecution
