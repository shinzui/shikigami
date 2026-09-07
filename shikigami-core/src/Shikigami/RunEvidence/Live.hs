-- | Fail closed when a caller tries to apply a rich projection without the
-- captured command data. Catalog inspection and registration never apply it.
module Shikigami.RunEvidence.Live (MissingLiveEvidence (..), requireLiveEvidence) where

import Control.Exception (Exception, throw)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Types (RecordedEvent)
import Shikigami.RunEvidence.Generated.Domain (RunEvidenceEvent)

data MissingLiveEvidence = MissingLiveEvidence
  deriving stock (Eq, Show)

instance Exception MissingLiveEvidence

-- | Rich evidence is encode-only and absent from lifecycle events. Only
-- persistEvidenceTransition may replace this guard with its captured handler.
requireLiveEvidence :: RunEvidenceEvent -> RecordedEvent -> Tx.Transaction ()
requireLiveEvidence _ _ = throw MissingLiveEvidence
