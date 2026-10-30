module Shikigami.Objective.Catalog (withLiveObjective) where

import Data.Generics.Labels ()
import Hasql.Transaction qualified as Tx
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (RecordedEvent)
import Shikigami.Generated.ProjectionCatalog qualified as Generated
import Shikigami.ObjectiveLifecycle.Generated.Domain (ObjectiveLifecycleEvent)
import Shikigami.Prelude

withLiveObjective :: (ObjectiveLifecycleEvent -> RecordedEvent -> Tx.Transaction ()) -> (Catalog.ValidatedProjectionCatalog, Catalog.ProjectionSet ObjectiveLifecycleEvent)
withLiveObjective apply = case Catalog.validateProjectionCatalog catalog of
  Catalog.Success validated -> (validated, projectionSet)
  Catalog.Failure diagnostics -> error ("invalid objective projection catalog: " <> show diagnostics)
  where
    projectionSet = Generated.objectiveWriterProjectionSet & #projectionDefinitions %~ fmap (\definition -> definition & #handlers %~ fmap replaceHandler)
    replaceHandler = \case
      Catalog.InlineHandler projection site -> Catalog.InlineHandler (projection & #apply .~ apply) site
      other -> other
    catalog = Generated.projectionCatalog & #projectionSets %~ map replaceSession
    replaceSession original@(Catalog.SomeProjectionSet existing)
      | existing.projectionSource == projectionSet.projectionSource = Catalog.SomeProjectionSet projectionSet
      | otherwise = original
