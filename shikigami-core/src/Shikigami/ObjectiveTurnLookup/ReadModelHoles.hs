-- Hand-owned protected query boundary; this module accepts no wire input.
module Shikigami.ObjectiveTurnLookup.ReadModelHoles
  ( ObjectiveTurnLookupQueryInput,
    ObjectiveTurnLookupQueryResult,
    objectiveTurnLookupQuery,
  )
where

import Data.Aeson (Value)
import Hasql.Transaction qualified as Tx

type ObjectiveTurnLookupQueryInput = Tx.Transaction Value

type ObjectiveTurnLookupQueryResult = Value

-- The catalog holds its read fence around the complete captured transaction.
objectiveTurnLookupQuery :: ObjectiveTurnLookupQueryInput -> Tx.Transaction ObjectiveTurnLookupQueryResult
objectiveTurnLookupQuery = id
