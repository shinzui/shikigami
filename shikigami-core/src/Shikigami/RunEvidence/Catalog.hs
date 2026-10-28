-- | One catalog authority for live evidence writes, queries and operations.
module Shikigami.RunEvidence.Catalog
  ( validatedProjectionCatalog,
    projectionCatalogInventory,
    registerProjectionCatalog,
    runEvidenceStoreRebuildGroupId,
    withLiveEvidence,
    auditTargets,
  )
where

import Control.Lens ((%~), (&), (.~))
import Data.Generics.Labels ()
import Hasql.Transaction qualified as Tx
import Keiro.Projection (InlineProjection (..))
import Keiro.Projection.Catalog qualified as Catalog
import Kiroku.Store.Types (RecordedEvent)
import Shikigami.Generated.ProjectionCatalog
  ( projectionCatalogInventory,
    registerProjectionCatalog,
    runEvidenceStoreRebuildGroupId,
    validatedProjectionCatalog,
  )
import Shikigami.Generated.ProjectionCatalog qualified as Generated
import Shikigami.Generated.ReplayAudit (auditTargets)
import Shikigami.RunEvidence.Generated.Domain (RunEvidenceEvent)

-- | Capture rich command data in a live handler, retaining every generated
-- ownership, reset and replay fact. Validate the resulting catalog before the
-- command transaction. This uses the released typed ProjectionSet boundary;
-- it does not encode rich data into lifecycle events or fabricate replay data.
withLiveEvidence ::
  (RunEvidenceEvent -> RecordedEvent -> Tx.Transaction ()) ->
  (Catalog.ValidatedProjectionCatalog, Catalog.ProjectionSet RunEvidenceEvent)
withLiveEvidence apply =
  case Catalog.validateProjectionCatalog catalog of
    Catalog.Success validated -> (validated, projectionSet)
    Catalog.Failure diagnostics -> error ("invalid live evidence catalog: " <> show diagnostics)
  where
    projectionSet =
      Generated.runEvidenceWriterProjectionSet
        & #projectionDefinitions
          %~ fmap
            ( \definition ->
                definition
                  & #handlers
                    %~ fmap
                      ( \case
                          Catalog.InlineHandler projection site ->
                            Catalog.InlineHandler (projection & #apply .~ apply) site
                          other -> other
                      )
            )
    catalog =
      Generated.projectionCatalog
        & #projectionSets %~ map replaceEvidence
    replaceEvidence original@(Catalog.SomeProjectionSet existing)
      | existing.projectionSource == projectionSet.projectionSource = Catalog.SomeProjectionSet projectionSet
      | otherwise = original
