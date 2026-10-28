-- | Application-owned attempt claims. Queue entries carry only JobReference;
-- they never allocate an attempt or grant replay/dispatch authority.
module Shikigami.Execution.Attempt where

import Data.Text qualified as Text
import Keiro.Workflow.Awakeable (AwakeableId)
import Shikigami.Execution.Identity
import Shikigami.Execution.Resources (AttemptRequest (..))
import Shikigami.Execution.Transcript
import Shikigami.Prelude
import Shikigami.Store.ExecutionSelection (CallLimits, CallOutcome, CallReceipt (..))

data JobReference = JobReference
  { format :: !Int,
    executionId :: !ExecutionId,
    operationId :: !OperationId,
    attemptId :: !AttemptId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON JobReference where
  parseJSON value = do
    reference <- genericParseJSON defaultOptions value
    unless (reference.format == 1) (fail "unsupported execution job version")
    pure reference

data ExecutionWake = ExecutionWake {token :: !AwakeableId, generation :: !Int}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ExecutionWake where show _ = "ExecutionWake <protected>"

data ModelCallPreparation = ModelCallPreparation
  { limits :: !CallLimits,
    fingerprint :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AttemptSubmission = AttemptSubmission
  { request :: !AttemptRequest,
    modelCall :: !(Maybe ModelCallPreparation),
    wake :: !ExecutionWake
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show AttemptSubmission where show _ = "AttemptSubmission <protected>"

data AttemptPhase = AwaitingDispatch | Claimed | DispatchStarted | AttemptCommitted | AttemptAbandoned | AttemptUncertain
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ExecutionAttempt = ExecutionAttempt
  { format :: !Int,
    executionId :: !ExecutionId,
    operationId :: !OperationId,
    request :: !AttemptRequest,
    fingerprint :: !Text,
    call :: !(Maybe CallReceipt),
    wake :: !PayloadRef,
    phase :: !AttemptPhase,
    owner :: !(Maybe Text),
    generation :: !Integer,
    expiresAt :: !(Maybe UTCTime),
    outcome :: !(Maybe PayloadRef),
    lateReceipt :: !(Maybe PayloadRef),
    uncertainty :: !(Maybe PayloadRef)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON ExecutionAttempt where
  parseJSON value = do
    attempt <- genericParseJSON defaultOptions value
    unless (attempt.format == 1 && attempt.request.operationId == attempt.operationId && attempt.generation >= 0 && not (Text.null attempt.fingerprint) && Text.length attempt.fingerprint <= 256) (fail "unsupported execution attempt identity")
    unless (maybe True (\receipt -> receipt.request == attempt.request) attempt.call) (fail "execution call receipt differs from its attempt")
    when (attempt.phase `elem` [Claimed, DispatchStarted, AttemptUncertain]) do
      unless (attempt.generation > 0 && maybe False (\owner -> not (Text.null owner) && Text.length owner <= 256) attempt.owner && isJust attempt.expiresAt) (fail "execution claim has no owner")
    pure attempt

data AttemptClaim = AttemptClaim
  { reference :: !JobReference,
    owner :: !Text,
    generation :: !Integer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ClaimResult = ClaimGranted !AttemptClaim | AttemptBusy | AttemptFinished | AttemptNeedsReconciliation
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AttemptResult = AttemptResult
  { outcome :: !OperationOutcome,
    next :: !NextWork,
    accounting :: !(Maybe CallOutcome)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show AttemptResult where show _ = "AttemptResult <protected>"
