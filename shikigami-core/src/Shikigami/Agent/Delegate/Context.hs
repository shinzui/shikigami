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
import Data.Aeson qualified as Aeson
import Keiro.Workflow.Types (WorkflowId (..), mkWorkflowId)
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
    executionPermissions :: !(Maybe [Text]),
    executionRootId :: !(Maybe ExecutionRootId),
    delegationBudgetId :: !(Maybe DelegationBudgetId),
    budgetLimit :: !DelegationBudget
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON DelegateCtx where
  toJSON context =
    Aeson.object
      [ "format" Aeson..= (1 :: Int),
        "depth" Aeson..= context.depth,
        "identity" Aeson..= context.identity,
        "sessionId" Aeson..= context.sessionId,
        "parentSessionId" Aeson..= context.parentSessionId,
        "parentRunWorkflowId" Aeson..= ((.unWorkflowId) <$> context.parentRunWorkflowId),
        "lineage" Aeson..= context.lineage,
        "executionPermissions" Aeson..= context.executionPermissions,
        "executionRootId" Aeson..= context.executionRootId,
        "delegationBudgetId" Aeson..= context.delegationBudgetId,
        "budgetLimit" Aeson..= context.budgetLimit
      ]

instance FromJSON DelegateCtx where
  parseJSON = Aeson.withObject "DelegateCtx" \fields -> do
    version <- fields Aeson..: "format"
    unless (version == (1 :: Int)) (fail "unsupported delegation snapshot version")
    parent <- fields Aeson..: "parentRunWorkflowId" >>= traverse (either (fail . show) pure . mkWorkflowId)
    DelegateCtx
      <$> fields Aeson..: "depth"
      <*> fields Aeson..: "identity"
      <*> fields Aeson..: "sessionId"
      <*> fields Aeson..: "parentSessionId"
      <*> pure parent
      <*> fields Aeson..: "lineage"
      <*> fields Aeson..: "executionPermissions"
      <*> fields Aeson..: "executionRootId"
      <*> fields Aeson..: "delegationBudgetId"
      <*> fields Aeson..: "budgetLimit"

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
checkDepth DelegateCtx {depth, identity, sessionId, parentSessionId, parentRunWorkflowId, lineage, delegationBudgetId, executionRootId, executionPermissions, budgetLimit} =
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
                executionPermissions,
                budgetLimit
              }
        else Left (DelegationDepthExceeded attemptedDepth)
