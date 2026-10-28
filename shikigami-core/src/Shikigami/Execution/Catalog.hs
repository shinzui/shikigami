-- | Capture protected command data without changing any catalog ownership.
module Shikigami.Execution.Catalog (withLiveExecution, executionStoreRebuildGroupId) where

import Data.Generics.Labels ()
import Hasql.Transaction qualified as Tx
import Keiro.Projection (InlineProjection (..))
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (RecordedEvent)
import Shikigami.ExecutionLifecycle.Generated.Domain (ExecutionLifecycleEvent)
import Shikigami.Generated.ProjectionCatalog (executionStoreRebuildGroupId)
import Shikigami.Generated.ProjectionCatalog qualified as Generated
import Shikigami.Prelude

withLiveExecution :: (ExecutionLifecycleEvent -> RecordedEvent -> Tx.Transaction ()) -> (Catalog.ValidatedProjectionCatalog, Catalog.ProjectionSet ExecutionLifecycleEvent)
withLiveExecution apply = case Catalog.validateProjectionCatalog catalog of
  Catalog.Success validated -> (validated, projectionSet)
  Catalog.Failure diagnostics -> error ("invalid execution projection catalog: " <> show diagnostics)
  where
    projectionSet = Generated.executionWriterProjectionSet & #projectionDefinitions %~ fmap (\definition -> definition & #handlers %~ fmap replaceHandler)
    replaceHandler = \case
      Catalog.InlineHandler projection site -> Catalog.InlineHandler (projection & #apply .~ apply) site
      other -> other
    catalog = Generated.projectionCatalog & #projectionSets %~ map replaceExecution
    replaceExecution original@(Catalog.SomeProjectionSet existing)
      | existing.projectionSource == projectionSet.projectionSource = Catalog.SomeProjectionSet projectionSet
      | otherwise = original
