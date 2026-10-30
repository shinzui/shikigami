-- | Shared native administrative authority. Never invent resource-aware hooks.
module Shikigami.Inspection.Catalog (inspectionHooks) where

import Keiro.Ops (AppHooks (..), emptyAppHooks)
import Keiro.Ops.Embed (OpsAuditConfig (..))
import Keiro.Projection.Catalog.Operations (projectionCatalogOperations)
import Shikigami.Inspection.Aggregates (aggregateCatalog)
import Shikigami.RunEvidence.Catalog qualified as Evidence

inspectionHooks :: AppHooks
inspectionHooks =
  emptyAppHooks
    { replayAudit = Just (OpsAuditConfig Evidence.auditTargets),
      projectionCatalog = Just (projectionCatalogOperations Evidence.validatedProjectionCatalog),
      aggregates = Just aggregateCatalog
    }
