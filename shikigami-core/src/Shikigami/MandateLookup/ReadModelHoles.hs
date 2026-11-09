-- Hand-owned protected query boundary; this module accepts no wire input.
module Shikigami.MandateLookup.ReadModelHoles
  ( MandateLookupQueryInput,
    MandateLookupQueryResult,
    mandateLookupQuery,
  )
where

import Data.Aeson (Value)
import Hasql.Transaction qualified as Tx

type MandateLookupQueryInput = Tx.Transaction Value

type MandateLookupQueryResult = Value

-- The catalog holds its read fence around the complete captured transaction.
mandateLookupQuery :: MandateLookupQueryInput -> Tx.Transaction MandateLookupQueryResult
mandateLookupQuery = id
