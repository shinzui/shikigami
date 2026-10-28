-- | Resource identity survives workflow generations and assignment handoffs.
module Shikigami.Execution.Identity (ExecutionRootId (..), OperationId (..), AttemptId (..), AllocationId (..)) where

import Shikigami.Prelude

newtype ExecutionRootId = ExecutionRootId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

newtype OperationId = OperationId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

newtype AttemptId = AttemptId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

newtype AllocationId = AllocationId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)
