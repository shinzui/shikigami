-- | Hand-owned query types at the generated read-model boundary.
module Shikigami.RunEvidenceLookup.ReadModelHoles
  ( RunEvidenceLookupQueryInput,
    RunEvidenceLookupQueryResult,
    runEvidenceLookupQuery,
  )
where

import Data.Text (Text)
import Hasql.Transaction qualified as Tx
import Shikigami.RunEvidence.Query (RawStoredRun, StoredCallEvidence, findRunTransaction)

type RunEvidenceLookupQueryInput = Text

type RunEvidenceLookupQueryResult = Maybe (RawStoredRun, [StoredCallEvidence])

runEvidenceLookupQuery :: RunEvidenceLookupQueryInput -> Tx.Transaction RunEvidenceLookupQueryResult
runEvidenceLookupQuery = findRunTransaction
