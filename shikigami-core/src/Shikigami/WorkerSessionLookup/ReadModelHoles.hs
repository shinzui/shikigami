-- Hand-owned protected query boundary; this module accepts no wire input.
module Shikigami.WorkerSessionLookup.ReadModelHoles
  ( WorkerSessionLookupQueryInput,
    WorkerSessionLookupQueryResult,
    workerSessionLookupQuery,
  )
where

import Data.Aeson (Value)
import Hasql.Transaction qualified as Tx

type WorkerSessionLookupQueryInput = Tx.Transaction Value

type WorkerSessionLookupQueryResult = Value

-- The catalog holds its read fence around the complete captured transaction.
workerSessionLookupQuery :: WorkerSessionLookupQueryInput -> Tx.Transaction WorkerSessionLookupQueryResult
workerSessionLookupQuery = id
