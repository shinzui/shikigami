-- Hand-owned protected query boundary; this module accepts no wire input.
module Shikigami.ObjectiveLookup.ReadModelHoles
  ( ObjectiveLookupQueryInput,
    ObjectiveLookupQueryResult,
    objectiveLookupQuery,
  )
where

import Data.Aeson (Value)
import Hasql.Transaction qualified as Tx

type ObjectiveLookupQueryInput = Tx.Transaction Value

type ObjectiveLookupQueryResult = Value

-- The catalog holds its read fence around the complete captured transaction.
objectiveLookupQuery :: ObjectiveLookupQueryInput -> Tx.Transaction ObjectiveLookupQueryResult
objectiveLookupQuery = id
