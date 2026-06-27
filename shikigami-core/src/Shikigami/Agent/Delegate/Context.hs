-- | Pure delegation context carried by an agent run.
module Shikigami.Agent.Delegate.Context
  ( DelegateCtx (..),
    DelegationError (..),
    maxDelegationDepth,
    checkDepth,
  )
where

import Control.Exception (Exception)
import Shikigami.Prelude

-- | Context a run needs to decide whether it may delegate further.
data DelegateCtx = DelegateCtx
  { delegateDepth :: !Int,
    parentSessionId :: !(Maybe Text),
    parentRunWorkflowId :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | Maximum allowed delegation depth. This mirrors Flue's four-level bound:
-- supervisor -> lead -> worker -> helper.
maxDelegationDepth :: Int
maxDelegationDepth = 4

-- | Delegation failed before creating a child.
data DelegationError
  = DelegationDepthExceeded !Int
  deriving stock (Eq, Show)

instance Exception DelegationError

-- | Validate that a child can be created and return the child's depth context.
checkDepth :: DelegateCtx -> Either DelegationError DelegateCtx
checkDepth ctx =
  let attemptedDepth = delegateDepth ctx + 1
   in if attemptedDepth < maxDelegationDepth
        then Right ctx {delegateDepth = attemptedDepth}
        else Left (DelegationDepthExceeded attemptedDepth)
