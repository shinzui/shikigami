{-# LANGUAGE DataKinds #-}

-- | Immutable admission and bounded generation handoff. Mutable session,
-- objective and budget facts remain in their owning stores.
module Shikigami.Coordination.Types where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Agent.Delegate.Context (DelegateCtx)
import Shikigami.Attestation.Resolve (ResolvedProfile)
import Shikigami.Coordination.Proposal (Policy)
import Shikigami.Decision.Contract (DecisionPolicySnapshot, ModelAlias)
import Shikigami.Execution.Coordinate (ExecutionDigest)
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Execution.Policy.Types (HarnessPolicy)
import Shikigami.Execution.Transcript (DecisionWorkLimits, ExecutionId, PayloadRef)
import Shikigami.Objective.Reference (ObjectiveAssociation)
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.WorkerSession.Capability (CoordinatorRun)
import Shikigami.WorkerSession.Types (WorkerSessionId)

data Admission = Admission
  { origin :: !CoordinatorRun,
    run :: !CoordinatorRun,
    objective :: !ObjectiveAssociation,
    ownerEpoch :: !(StateRevision "worker-owner"),
    declaration :: !AgentDecl,
    declarations :: ![AgentDecl],
    context :: !DelegateCtx,
    organization :: !Policy,
    decisions :: !DecisionPolicySnapshot,
    profile :: !(Maybe ResolvedProfile),
    harness :: !HarnessPolicy,
    decisionLimits :: !DecisionWorkLimits,
    instructions :: !Text,
    request :: !Value
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

data PendingDecision = PendingDecision
  { operationId :: !OperationId,
    nextOperation :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SessionReference = SessionReference
  { assignmentId :: !ObjectiveAssignmentId,
    sessionId :: !WorkerSessionId,
    scope :: !(ExecutionDigest "coordination-scope"),
    after :: !(StateRevision "worker-event")
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- A direct result is a protected execution reference, never a copied output or
-- a model assertion that the objective has passed its checks.
data DirectResult = DirectResult
  { assignmentId :: !ObjectiveAssignmentId,
    operationId :: !OperationId,
    executionId :: !ExecutionId,
    result :: !PayloadRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ReadyAssignment = ReadyAssignment
  { assignmentId :: !ObjectiveAssignmentId,
    operationId :: !OperationId,
    decisionId :: !OperationId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data TransferReference = TransferReference
  {assignmentId :: !ObjectiveAssignmentId, sessionId :: !WorkerSessionId, scope :: !(ExecutionDigest "coordination-scope"), operationId :: !OperationId}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data EvidenceMark = EvidenceMark
  { instructions :: !(StateRevision "objective-instructions"),
    criteria :: !(StateRevision "objective-criteria"),
    graph :: ![Text],
    actions :: ![NextAction],
    results :: ![Text],
    checks :: ![EvidenceKey],
    unresolved :: ![UnresolvedOperation]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Seed = Seed
  { admission :: !(Maybe Admission),
    pending :: !(Maybe PendingDecision),
    lastDecision :: !(Maybe OperationId),
    sessions :: ![SessionReference],
    ready :: ![ReadyAssignment],
    directResults :: ![DirectResult],
    modelSelections :: ![(ObjectiveAssignmentId, ModelAlias)],
    observed :: !(Maybe EvidenceMark),
    reflect :: !Bool,
    concurrency :: !Int,
    refusal :: !(Maybe Text),
    transfer :: !(Maybe TransferReference)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance FromJSON Seed where
  parseJSON = Aeson.withObject "AdaptiveSeed" \fields -> Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object (if KeyMap.member "transfer" fields then fields else KeyMap.insert "transfer" Aeson.Null fields))

initialSeed :: Seed
initialSeed = Seed Nothing Nothing Nothing [] [] [] [] Nothing True 1 Nothing Nothing

data DeliveryResult = DeliveryResult
  { objectiveId :: !ObjectiveId,
    revision :: !(StateRevision "objective"),
    decision :: !(Maybe OperationId),
    status :: !Text,
    refusal :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
