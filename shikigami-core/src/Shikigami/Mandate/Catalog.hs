module Shikigami.Mandate.Catalog (withLiveMandate) where

import Data.Generics.Labels ()
import Hasql.Transaction qualified as Tx
import Keiro.Projection (InlineProjection (..))
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (RecordedEvent)
import Shikigami.Generated.ProjectionCatalog qualified as Generated
import Shikigami.MandateLifecycle.Generated.Domain (MandateLifecycleEvent)
import Shikigami.Prelude

withLiveMandate :: (MandateLifecycleEvent -> RecordedEvent -> Tx.Transaction ()) -> (Catalog.ValidatedProjectionCatalog, Catalog.ProjectionSet MandateLifecycleEvent)
withLiveMandate apply = case Catalog.validateProjectionCatalog catalog of
  Catalog.Success validated -> (validated, projectionSet)
  Catalog.Failure diagnostics -> error ("invalid mandate projection catalog: " <> show diagnostics)
  where
    projectionSet = Generated.mandateWriterProjectionSet & #projectionDefinitions %~ fmap (\definition -> definition & #handlers %~ fmap replaceHandler)
    replaceHandler = \case
      Catalog.InlineHandler projection site -> Catalog.InlineHandler (projection & #apply .~ apply) site
      other -> other
    catalog = Generated.projectionCatalog & #projectionSets %~ map replace
    replace original@(Catalog.SomeProjectionSet existing)
      | existing.projectionSource == projectionSet.projectionSource = Catalog.SomeProjectionSet projectionSet
      | otherwise = original
