-- | Hand-owned bridge to the live evidence boundary. Never reconstruct rich
-- payloads from lifecycle history or accept an unbound application callback.
module Shikigami.ProjectionCatalog.ProjectionCatalogHoles (applyRunEvidenceWriterLive) where

import Hasql.Transaction qualified as Tx
import Kiroku.Store.Types (RecordedEvent)
import Shikigami.RunEvidence.Generated.Domain (RunEvidenceEvent)
import Shikigami.RunEvidence.Live (requireLiveEvidence)

applyRunEvidenceWriterLive :: RunEvidenceEvent -> RecordedEvent -> Tx.Transaction ()
applyRunEvidenceWriterLive = requireLiveEvidence
