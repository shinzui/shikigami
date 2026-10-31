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
import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Keiro.Workflow.Types (WorkflowId (..), mkWorkflowId)
import Kioku.Id (SessionId)
import Shikigami.Agent.Decl (AgentDecl (..), DelegationBudget)
import Shikigami.Agent.Delegate.Depth (DelegationDepth, depthInt, parseDelegationDepth)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Decision.ModelAlias (ModelAlias)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Prelude hiding ((.=))

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
    executionPermissions :: !(Maybe [ModelAlias]),
    executionRootId :: !(Maybe ExecutionRootId),
    delegationBudgetId :: !(Maybe DelegationBudgetId),
    budgetLimit :: !DelegationBudget
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON DelegateCtx where
  toJSON context =
    Aeson.object
      [ "format" .= (1 :: Int),
        "depth" .= context.depth,
        "identity" .= context.identity,
        "sessionId" .= context.sessionId,
        "parentSessionId" .= context.parentSessionId,
        "parentRunWorkflowId" .= ((.unWorkflowId) <$> context.parentRunWorkflowId),
        "lineage" .= context.lineage,
        "executionPermissions" .= context.executionPermissions,
        "executionRootId" .= context.executionRootId,
        "delegationBudgetId" .= context.delegationBudgetId,
        "budgetLimit" .= context.budgetLimit
      ]

instance FromJSON DelegateCtx where
  parseJSON = Aeson.withObject "DelegateCtx" \fields -> do
    version <- fields .: "format"
    unless (version == (1 :: Int)) (fail "unsupported delegation snapshot version")
    parent <- fields .: "parentRunWorkflowId" >>= traverse (either (fail . show) pure . mkWorkflowId)
    DelegateCtx
      <$> fields .: "depth"
      <*> fields .: "identity"
      <*> fields .: "sessionId"
      <*> fields .: "parentSessionId"
      <*> pure parent
      <*> fields .: "lineage"
      <*> fields .: "executionPermissions"
      <*> fields .: "executionRootId"
      <*> fields .: "delegationBudgetId"
      <*> fields .: "budgetLimit"

-- | Exclusive depth bound for supervisor, lead, worker and helper levels.
maxDelegationDepth :: Int
maxDelegationDepth = 4

-- | Delegation failed before creating a child.
data DelegationError
  = DelegationDepthExceeded !Integer
  | DelegationMissingSessionId
  | DelegationCycleDetected !AgentName
  | DelegationBudgetExhausted
  | DelegationBudgetUnavailable !Text
  | DelegationNotAllowed !AgentName
  | DelegationIdentityRefused !Text
  | DelegatedChildCancelled
  | DelegatedChildFailed !Text
  | DelegatedResultDecodeFailed !Text
  deriving stock (Eq, Show)

instance Exception DelegationError

-- | Refuse any target the delegating agent did not declare explicitly.
assertMayDelegate :: AgentDecl -> AgentName -> Either DelegationError ()
assertMayDelegate AgentDecl {delegates} target
  | target `elem` delegates = Right ()
  | otherwise = Left (DelegationNotAllowed target)

-- | Refuse an edge back to the current agent or any of its ancestors.
checkCycle :: DelegateCtx -> AgentName -> Either DelegationError ()
checkCycle DelegateCtx {lineage} target
  | target `elem` lineage = Left (DelegationCycleDetected target)
  | otherwise = Right ()

-- | Validate that a child can be created and return the child's depth context.
checkDepth :: DelegateCtx -> Either DelegationError DelegateCtx
checkDepth DelegateCtx {depth, identity, sessionId, parentSessionId, parentRunWorkflowId, lineage, delegationBudgetId, executionRootId, executionPermissions, budgetLimit} =
  let attemptedDepth = toInteger (depthInt depth) + 1
   in if attemptedDepth < toInteger maxDelegationDepth
        then do
          childDepth <- either (const (Left (DelegationDepthExceeded attemptedDepth))) Right (parseDelegationDepth attemptedDepth)
          Right
            DelegateCtx
              { depth = childDepth,
                identity,
                sessionId,
                parentSessionId,
                parentRunWorkflowId,
                lineage,
                delegationBudgetId,
                executionRootId,
                executionPermissions,
                budgetLimit
              }
        else Left (DelegationDepthExceeded attemptedDepth)
