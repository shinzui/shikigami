module Shikigami.Objective.Catalog (withLiveObjective, withLiveObjectiveTurn) where

import Data.Generics.Labels ()
import Hasql.Transaction qualified as Tx
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (RecordedEvent)
import Shikigami.Generated.ProjectionCatalog qualified as Generated
import Shikigami.ObjectiveLifecycle.Generated.Domain (ObjectiveLifecycleEvent)
import Shikigami.ObjectiveTurnAdmission.Generated.Domain (ObjectiveTurnAdmissionEvent)
import Shikigami.Prelude

withLiveObjective :: (ObjectiveLifecycleEvent -> RecordedEvent -> Tx.Transaction ()) -> (ObjectiveLifecycleEvent -> RecordedEvent -> Tx.Transaction ()) -> (Catalog.ValidatedProjectionCatalog, Catalog.ProjectionSet ObjectiveLifecycleEvent)
withLiveObjective objective tracker = withLive combined select
  where
    combined = Generated.objectiveWriterProjectionSet & #projectionDefinitions %~ (<> Generated.objectiveTrackerWriterProjectionSet.projectionDefinitions)
    select identifier = if Catalog.projectionIdText identifier == "objective_tracker_writer" then tracker else objective

withLiveObjectiveTurn :: (ObjectiveTurnAdmissionEvent -> RecordedEvent -> Tx.Transaction ()) -> (Catalog.ValidatedProjectionCatalog, Catalog.ProjectionSet ObjectiveTurnAdmissionEvent)
withLiveObjectiveTurn apply = withLive Generated.objectiveTurnWriterProjectionSet (const apply)

withLive :: Catalog.ProjectionSet event -> (Catalog.ProjectionId -> event -> RecordedEvent -> Tx.Transaction ()) -> (Catalog.ValidatedProjectionCatalog, Catalog.ProjectionSet event)
withLive originalSet apply = case Catalog.validateProjectionCatalog catalog of
  Catalog.Success validated -> (validated, projectionSet)
  Catalog.Failure diagnostics -> error ("invalid objective projection catalog: " <> show diagnostics)
  where
    projectionSet = originalSet & #projectionDefinitions %~ fmap (\definition -> definition & #handlers %~ fmap (replaceHandler definition.projectionId))
    replaceHandler identifier = \case
      Catalog.InlineHandler projection site -> Catalog.InlineHandler (projection & #apply .~ apply identifier) site
      other -> other
    catalog = Generated.projectionCatalog & #projectionSets %~ (\sets -> Catalog.SomeProjectionSet projectionSet : filter differentSource sets)
    differentSource (Catalog.SomeProjectionSet existing) = existing.projectionSource /= projectionSet.projectionSource
