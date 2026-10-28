-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module Shikigami.ExecutionLookup.ReadModelHoles
  ( ExecutionLookupQueryInput,
    ExecutionLookupQueryResult,
    executionLookupQuery,
  )
where

import Data.Aeson (Value)
import Hasql.Transaction qualified as Tx

-- Execution.Store captures its bounded, schema-qualified query together with
-- any private replay permit. The registered model checks schema/liveness and
-- holds its catalog read fence around that entire transaction callback.
-- This module is private to the library and accepts no wire input.
type ExecutionLookupQueryInput = Tx.Transaction Value

type ExecutionLookupQueryResult = Value

executionLookupQuery :: ExecutionLookupQueryInput -> Tx.Transaction ExecutionLookupQueryResult
executionLookupQuery = id
