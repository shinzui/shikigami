-- | Protected tracker reads stay inside the catalog query fence.
module Shikigami.ObjectiveTrackerLookup.ReadModelHoles where

import Data.Aeson (Value)
import Hasql.Transaction qualified as Tx

type ObjectiveTrackerLookupQueryInput = Tx.Transaction Value

type ObjectiveTrackerLookupQueryResult = Value

objectiveTrackerLookupQuery :: ObjectiveTrackerLookupQueryInput -> Tx.Transaction ObjectiveTrackerLookupQueryResult
objectiveTrackerLookupQuery = id
