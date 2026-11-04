module Shikigami.Coordination.Identity (adaptiveWorkflowId, admittedAdaptiveWorkflowId) where

import Data.Aeson (object, (.=))
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID
import Keiro.Workflow (WorkflowId (..))
import Shikigami.Coordination.Types (Admission (..))
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Objective.Reference (ObjectiveAssociation)
import Shikigami.Prelude (nameBytes)
import Shikigami.WorkerSession.Capability (CoordinatorRun (..))

adaptiveWorkflowId :: CoordinatorRun -> ObjectiveAssociation -> WorkflowId
adaptiveWorkflowId origin objective = WorkflowId (UUID.toText (UUID.generateNamed UUID.namespaceURL (nameBytes (versionedDigest "shikigami.adaptive-delivery-workflow/1" (object ["origin" .= origin, "objective" .= objective])))))

admittedAdaptiveWorkflowId :: Admission -> WorkflowId
admittedAdaptiveWorkflowId admission = admission.run.runId
