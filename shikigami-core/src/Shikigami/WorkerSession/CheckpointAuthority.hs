{-# LANGUAGE DataKinds #-}

-- | Package-private proof of an immutable non-commit observed at its owner.
-- Durable metadata can be inspected; it cannot decode a process-local grant.
module Shikigami.WorkerSession.CheckpointAuthority where

import Shikigami.FormatVersion (FormatVersion)
import Shikigami.Prelude
import Shikigami.WorkerSession.Checkpoint (CheckpointIntent)
import Shikigami.WorkerSession.Input (ProviderReceipt)

data CheckpointRejection = CheckpointRejection
  { format :: !(FormatVersion "checkpoint-rejection"),
    intent :: !CheckpointIntent,
    source :: !ProviderReceipt,
    refusal :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype RejectionAuthority = RejectionAuthority CheckpointRejection
