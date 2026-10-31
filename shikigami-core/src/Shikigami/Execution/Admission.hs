-- | Explicit enrollment for a newly admitted root run. Historical producers
-- keep Nothing; workers never manufacture missing resource envelopes.
module Shikigami.Execution.Admission (enrollRootRun) where

import Data.Generics.Labels ()
import Effectful (Eff, IOE, (:>))
import Kiroku.Store.Effect (Store)
import Shikigami.Agent.Delegate.Depth (depthInt)
import Shikigami.Agent.Principal (resolveAgentIdentity)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Execution.Resources (Envelope, ResourceError (..))
import Shikigami.Execution.ResourcesStore (allocateRootForWorkflow)
import Shikigami.Prelude

enrollRootRun :: (Store :> es, IOE :> es) => Envelope -> RunJob -> Eff es (Either ResourceError RunJob)
enrollRootRun envelope job
  | isJust job.parentRunWorkflowId || isJust job.parentSessionId || isJust job.delegationBudgetId || maybe False ((/= 0) . depthInt) job.delegationDepth =
      pure (Left (InvalidResourceRequest "descendants cannot enroll a resource root"))
  | otherwise = case resolveAgentIdentity job.identity of
      Left _ -> pure (Left (InvalidResourceRequest "resource root requires a resolved creator"))
      Right creator -> do
        admitted <- allocateRootForWorkflow creator job.agentName (runJobWorkflowId job) job.executionRootId envelope
        pure ((\root -> job & #executionRootId .~ Just root) <$> admitted)
