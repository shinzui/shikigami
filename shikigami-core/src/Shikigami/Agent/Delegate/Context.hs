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
import Shikigami.Agent.Decl (AgentDecl (..), DelegationBudget)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Prelude

-- | Identity of the one durable descendant budget shared by a complete
-- delegation tree. It is encoded as a scalar so additive 'RunJob' fields stay
-- compact and unambiguous on the queue and in workflow journals.
newtype DelegationBudgetId = DelegationBudgetId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Context a run needs to decide whether it may delegate further.
data DelegateCtx = DelegateCtx
  { delegateDepth :: !Int,
    identity :: !AgentIdentity,
    sessionId :: !(Maybe Text),
    parentSessionId :: !(Maybe Text),
    parentRunWorkflowId :: !(Maybe Text),
    lineage :: ![Text],
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
  = DelegationDepthExceeded !Int
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
  | target `elem` lineage = Left (DelegationCycleDetected target)
  | otherwise = Right ()

-- | Validate that a child can be created and return the child's depth context.
checkDepth :: DelegateCtx -> Either DelegationError DelegateCtx
checkDepth DelegateCtx {delegateDepth, identity, sessionId, parentSessionId, parentRunWorkflowId, lineage, delegationBudgetId, budgetLimit} =
  let attemptedDepth = delegateDepth + 1
   in if attemptedDepth < maxDelegationDepth
        then
          Right
            DelegateCtx
              { delegateDepth = attemptedDepth,
                identity,
                sessionId,
                parentSessionId,
                parentRunWorkflowId,
                lineage,
                delegationBudgetId,
                budgetLimit
              }
        else Left (DelegationDepthExceeded attemptedDepth)
