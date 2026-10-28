module Shikigami.WorkerSession.Catalog (withLiveSession) where

import Data.Generics.Labels ()
import Hasql.Transaction qualified as Tx
import Keiro.Projection (InlineProjection (..))
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (RecordedEvent)
import Shikigami.Generated.ProjectionCatalog qualified as Generated
import Shikigami.Prelude
import Shikigami.WorkerSessionLifecycle.Generated.Domain (WorkerSessionLifecycleEvent)

withLiveSession :: (WorkerSessionLifecycleEvent -> RecordedEvent -> Tx.Transaction ()) -> (Catalog.ValidatedProjectionCatalog, Catalog.ProjectionSet WorkerSessionLifecycleEvent)
withLiveSession apply = case Catalog.validateProjectionCatalog catalog of
  Catalog.Success validated -> (validated, projectionSet)
  Catalog.Failure diagnostics -> error ("invalid session projection catalog: " <> show diagnostics)
  where
    projectionSet = Generated.workerSessionWriterProjectionSet & #projectionDefinitions %~ fmap (\definition -> definition & #handlers %~ fmap replaceHandler)
    replaceHandler = \case
      Catalog.InlineHandler projection site -> Catalog.InlineHandler (projection & #apply .~ apply) site
      other -> other
    catalog = Generated.projectionCatalog & #projectionSets %~ map replaceSession
    replaceSession original@(Catalog.SomeProjectionSet existing)
      | existing.projectionSource == projectionSet.projectionSource = Catalog.SomeProjectionSet projectionSet
      | otherwise = original
