-- | Explicit enrollment for a newly admitted root run. Historical producers
-- keep Nothing; workers never manufacture missing resource envelopes.
module Shikigami.Execution.Admission (enrollRootRun) where

import Data.Generics.Labels ()
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID
import Effectful (Eff, (:>))
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Effect (Store)
import Shikigami.Agent.Delegate.Depth (depthInt)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Execution.Identity (ExecutionRootId (..))
import Shikigami.Execution.Resources (Envelope, ResourceError (..))
import Shikigami.Execution.ResourcesStore (enrollRoot)
import Shikigami.Prelude

enrollRootRun :: (Store :> es) => Envelope -> RunJob -> Eff es (Either ResourceError RunJob)
enrollRootRun envelope job
  | isJust job.parentRunWorkflowId || isJust job.parentSessionId || isJust job.delegationBudgetId || maybe False ((/= 0) . depthInt) job.delegationDepth =
      pure (Left (InvalidResourceRequest "descendants cannot enroll a resource root"))
  | maybe False (/= rootId) job.executionRootId = pure (Left IdentityConflict)
  | otherwise = do
      admitted <- enrollRoot rootId envelope
      pure ((\_ -> job & #executionRootId .~ Just rootId) <$> admitted)
  where
    WorkflowId workflow = runJobWorkflowId job
    rootId = ExecutionRootId (UUID.toText (UUID.generateNamed UUID.namespaceURL (nameBytes ("shikigami:execution-root:" <> workflow))))
