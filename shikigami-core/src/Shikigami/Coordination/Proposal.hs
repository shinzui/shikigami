{-# LANGUAGE DataKinds #-}

-- | Closed, versioned organization proposals. These values describe desired
-- changes; only the checkpoint owner can admit them. No executable code or
-- provider/tool credentials can be selected by this vocabulary.
module Shikigami.Coordination.Proposal where

import Data.Aeson qualified as Aeson
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Decision.ModelAlias (ModelAlias)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.FormatVersion (FormatVersion)
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.WorkerSession.Capability (WorkerInstruction)
import Shikigami.WorkerSession.Transfer (WorkspaceRef)

-- The catalog is a pinned upper bound. Fresh authority may only narrow it.
data Target = Target
  { name :: !AgentName,
    identity :: !AgentIdentity,
    parents :: ![AgentName],
    models :: ![ModelAlias]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Policy = Policy
  { format :: !(FormatVersion "adaptive-policy"),
    coordinator :: !AgentName,
    identity :: !AgentIdentity,
    rootId :: !ExecutionRootId,
    cutoff :: !UTCTime,
    targets :: ![Target],
    maximumDepth :: !Int,
    maximumAssignments :: !Int,
    maximumConcurrency :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Placement = Placement
  { assignment :: !AssignmentDraft,
    target :: !AgentName,
    parent :: !(Maybe ObjectiveAssignmentId)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON Placement where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

-- Checks refer to verifier-owned evidence, including the exact combined
-- artifact and user journey. A completion proposal never accepts itself.
data IntegratedAcceptance = IntegratedAcceptance
  { objectiveRevision :: !(StateRevision "objective"),
    instructionsRevision :: !(StateRevision "objective-instructions"),
    criteriaRevision :: !(StateRevision "objective-criteria"),
    artifacts :: ![ArtifactRef],
    checks :: ![EvidenceKey],
    limitations :: ![CompletionLimitation]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON IntegratedAcceptance where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

data Change
  = DirectWork !ObjectiveAssignmentId !WorkerInstruction
  | CreateAssignment !Placement
  | NarrowAssignment !ObjectiveAssignmentId !Instructions
  | SplitAssignment !ObjectiveAssignmentId ![Placement]
  | ConsolidateAssignments ![ObjectiveAssignmentId] !Placement
  | FollowUpContext !ObjectiveAssignmentId !WorkerInstruction
  | TransferAssignment !ObjectiveAssignmentId !AgentName !WorkspaceRef
  | EscalateModel !ObjectiveAssignmentId !ModelAlias
  | ChangeConcurrency !Int
  | IntegrateResult !ObjectiveAssignmentId !EvidenceInput
  | AwaitAssignments ![ObjectiveAssignmentId]
  | ProposeCompletion !IntegratedAcceptance
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON Change where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

data Proposal = Proposal
  { format :: !(FormatVersion "adaptive-proposal"),
    objectiveId :: !ObjectiveId,
    checkpointRevision :: !(StateRevision "objective"),
    instructionsRevision :: !(StateRevision "objective-instructions"),
    criteriaRevision :: !(StateRevision "objective-criteria"),
    operationId :: !OperationId,
    evidence :: ![EvidenceKey],
    rationale :: !CriterionDescription,
    friction :: !(Maybe CriterionDescription),
    expectedBenefit :: !CriterionDescription,
    laterEvidence :: !EvidenceKey,
    changes :: ![Change]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON Proposal where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

-- Retained operation keys are derived from the proposal key and ordinal. An
-- uncertain acknowledgement must reconcile these same keys.
data ExecutableOperation = ExecutableOperation
  { operationId :: !OperationId,
    change :: !Change
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AcceptedDecision = AcceptedDecision
  { format :: !(FormatVersion "adaptive-decision"),
    validatorVersion :: !Text,
    policy :: !Policy,
    proposal :: !Proposal,
    checkpointDigest :: !Text,
    arrangement :: ![Placement],
    operations :: ![ExecutableOperation]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

completionProposal :: IntegratedAcceptance -> CompletionProposal
completionProposal value = CompletionProposal value.objectiveRevision value.instructionsRevision value.criteriaRevision value.artifacts value.checks value.limitations
