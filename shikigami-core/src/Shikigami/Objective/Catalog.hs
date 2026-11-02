module Shikigami.Objective.Catalog (withLiveObjective, withLiveObjectiveTurn) where

import Data.Generics.Labels ()
import Hasql.Transaction qualified as Tx
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (RecordedEvent)
import Shikigami.Generated.ProjectionCatalog qualified as Generated
import Shikigami.ObjectiveLifecycle.Generated.Domain (ObjectiveLifecycleEvent)
import Shikigami.ObjectiveTurnAdmission.Generated.Domain (ObjectiveTurnAdmissionEvent)
import Shikigami.Prelude

withLiveObjective :: (ObjectiveLifecycleEvent -> RecordedEvent -> Tx.Transaction ()) -> (Catalog.ValidatedProjectionCatalog, Catalog.ProjectionSet ObjectiveLifecycleEvent)
withLiveObjective = withLive Generated.objectiveWriterProjectionSet

withLiveObjectiveTurn :: (ObjectiveTurnAdmissionEvent -> RecordedEvent -> Tx.Transaction ()) -> (Catalog.ValidatedProjectionCatalog, Catalog.ProjectionSet ObjectiveTurnAdmissionEvent)
withLiveObjectiveTurn = withLive Generated.objectiveTurnWriterProjectionSet

withLive :: Catalog.ProjectionSet event -> (event -> RecordedEvent -> Tx.Transaction ()) -> (Catalog.ValidatedProjectionCatalog, Catalog.ProjectionSet event)
withLive originalSet apply = case Catalog.validateProjectionCatalog catalog of
  Catalog.Success validated -> (validated, projectionSet)
  Catalog.Failure diagnostics -> error ("invalid objective projection catalog: " <> show diagnostics)
  where
    projectionSet = originalSet & #projectionDefinitions %~ fmap (\definition -> definition & #handlers %~ fmap replaceHandler)
    replaceHandler = \case
      Catalog.InlineHandler projection site -> Catalog.InlineHandler (projection & #apply .~ apply) site
      other -> other
    catalog = Generated.projectionCatalog & #projectionSets %~ map replaceSession
    replaceSession original@(Catalog.SomeProjectionSet existing)
      | existing.projectionSource == projectionSet.projectionSource = Catalog.SomeProjectionSet projectionSet
      | otherwise = original
