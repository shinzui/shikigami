-- | Pure delegation context carried by an agent run.
module Shikigami.Agent.Delegate.Context
  ( DelegateCtx (..),
    DelegationBudgetId (..),
    DelegationError (..),
    maxDelegationDepth,
    assertMayDelegate,
    checkCycle,
    checkDepth,
  )
where

import Control.Exception (Exception)
import Keiro.Workflow.Types (WorkflowId)
import Kioku.Id (SessionId)
import Shikigami.Agent.Decl (AgentDecl (..), DelegationBudget)
import Shikigami.Agent.Delegate.Depth (DelegationDepth (..), depthInt)
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Prelude

-- | Identity of the one durable descendant budget shared by a complete
-- delegation tree. It is encoded as a scalar so additive 'RunJob' fields stay
-- compact and unambiguous on the queue and in workflow journals.
newtype DelegationBudgetId = DelegationBudgetId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Context a run needs to decide whether it may delegate further.
data DelegateCtx = DelegateCtx
  { depth :: !DelegationDepth,
    identity :: !AgentIdentity,
    sessionId :: !(Maybe SessionId),
    parentSessionId :: !(Maybe SessionId),
    parentRunWorkflowId :: !(Maybe WorkflowId),
    lineage :: ![AgentName],
    executionRootId :: !(Maybe ExecutionRootId),
    delegationBudgetId :: !(Maybe DelegationBudgetId),
    budgetLimit :: !DelegationBudget
  }
  deriving stock (Eq, Show, Generic)

-- | Maximum allowed delegation depth. This mirrors Flue's four-level bound:
-- supervisor -> lead -> worker -> helper.
maxDelegationDepth :: Int
maxDelegationDepth = 4

-- | Delegation failed before creating a child.
data DelegationError
  = DelegationDepthExceeded !Integer
  | DelegationMissingSessionId
  | DelegationCycleDetected !Text
  | DelegationBudgetExhausted
  | DelegationBudgetUnavailable !Text
  | DelegationNotAllowed !Text
  | DelegationIdentityRefused !Text
  | DelegatedChildCancelled
  | DelegatedChildFailed !Text
  | DelegatedResultDecodeFailed !Text
  deriving stock (Eq, Show)

instance Exception DelegationError

-- | Refuse any target the delegating agent did not declare explicitly.
assertMayDelegate :: AgentDecl -> Text -> Either DelegationError ()
assertMayDelegate AgentDecl {delegates} target
  | target `elem` delegates = Right ()
  | otherwise = Left (DelegationNotAllowed target)

-- | Refuse an edge back to the current agent or any of its ancestors.
checkCycle :: DelegateCtx -> Text -> Either DelegationError ()
checkCycle DelegateCtx {lineage} target
  | AgentName target `elem` lineage = Left (DelegationCycleDetected target)
  | otherwise = Right ()

-- | Validate that a child can be created and return the child's depth context.
checkDepth :: DelegateCtx -> Either DelegationError DelegateCtx
checkDepth DelegateCtx {depth, identity, sessionId, parentSessionId, parentRunWorkflowId, lineage, delegationBudgetId, executionRootId, budgetLimit} =
  let attemptedDepth = toInteger (depthInt depth) + 1
   in if attemptedDepth < toInteger maxDelegationDepth
        then
          Right
            DelegateCtx
              { depth = DelegationDepth (fromInteger attemptedDepth),
                identity,
                sessionId,
                parentSessionId,
                parentRunWorkflowId,
                lineage,
                delegationBudgetId,
                executionRootId,
                budgetLimit
              }
        else Left (DelegationDepthExceeded attemptedDepth)
