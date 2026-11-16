-- | Enrolling a scheduled tick under a pack's allowance (ADR-119).
--
-- The pack decides whether a tick has an allowance
-- ("Shikigami.Trigger.Hook"). This is the rest: recover a resource root at
-- the run's native workflow origin, with the allowance's limits, and bind it
-- to the run job. It runs in the transaction that enqueues the job, so a tick
-- commits a funded run or nothing. Recovery is idempotent at the origin, so a
-- timer that fires twice enrolls one root.
module Shikigami.Trigger.Enrollment (enrollScheduledRootTx) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime)
import Hasql.Transaction (Transaction)
import Shikigami.Agent.Principal (AgentIdentity (..), resolveAgentIdentity)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Execution.Resources (Envelope (..))
import Shikigami.Execution.ResourcesStore (recoverRootForWorkflowTx)
import Shikigami.Trigger.Hook (ScheduledAllowance (..))

-- | Bind a new root to a scheduled run. Only a new root run of the
-- allowance's own principal is enrolled: a delegated run, or one that already
-- carries a root, is refused, because its spend belongs to whoever started it.
enrollScheduledRootTx :: ExecutionRootId -> ScheduledAllowance -> UTCTime -> RunJob -> Transaction (Either Text RunJob)
enrollScheduledRootTx candidate allowance now job
  | job.identity /= VerifiedIdentity allowance.principal || job.parentRunWorkflowId /= Nothing || job.parentSessionId /= Nothing || job.delegationBudgetId /= Nothing || job.delegationDepth /= Nothing || job.executionRootId /= Nothing = pure (Left "scheduled enrollment requires the bound new root run")
  | otherwise = case resolveAgentIdentity job.identity of
      Left _ -> pure (Left "scheduled identity is unresolved")
      Right creator -> do
        root <- recoverRootForWorkflowTx candidate creator job.agentName (runJobWorkflowId job) (Envelope allowance.limits (addUTCTime allowance.lifetime now))
        pure case root of
          Left _ -> Left "scheduled resource enrollment refused"
          Right identifier -> Right (job & #executionRootId .~ Just identifier)
