{-# LANGUAGE DataKinds #-}

module Shikigami.Objective.Command where

import Data.Aeson qualified as Aeson
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Coordination.Proposal (AcceptedDecision (..), Change (IntegrateResult), ExecutableOperation (..))
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.WorkerSession.Capability (CoordinationScope)
import Shikigami.WorkerSession.Checkpoint (CheckpointIntent)
import Shikigami.WorkerSession.Transfer (FenceProof, TransferIntent)

-- | This is the entire public vocabulary. Internal commands have no public
-- JSON tags and cannot be selected by a public command envelope.
data Command
  = ReviseInstructions !Instructions
  | ReviseCriteria ![Criterion]
  | SetAssignments ![AssignmentDraft]
  | RecordProgress !ObjectiveAssignmentId !AssignmentState ![DecisionNote] ![AssumptionNote]
  | RecordEvidence !ObjectiveAssignmentId !EvidenceInput
  | SetNextAction ![NextAction]
  | SetBlocked !BlockState
  | ProposeCompletion !CompletionProposal
  | AcceptCompletion
  | CancelObjective
  | GrantMember !AccessPrincipal ![Role]
  | RevokeMember !AccessPrincipal
  | BindConversation !ConversationRef
  | LinkExternal !ExternalReference
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON Command where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

-- | Constructed only by provider adapters with verified source/fence context.
-- No FromJSON instance: these are absent from HTTP and model vocabularies.
data InternalCommand
  = ApplyAdaptiveDecision !AcceptedDecision
  | IngestCheckpoint !ObjectiveAssignmentId !CheckpointIntent ![EvidenceInput] ![UnresolvedOperation]
  | ProjectCheckpoint !ObjectiveAssignmentId !CheckpointIntent
  | RetainCoordination !ObjectiveAssignmentId !CoordinationScope
  | TransferSessionOwnership !ObjectiveAssignmentId !TransferIntent !FenceProof
  | TransferOwnership !ObjectiveAssignmentId !(StateRevision "worker-owner") !AgentIdentity
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data Mutation = Public !Command | Internal !InternalCommand
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

commandTag :: Mutation -> Text
commandTag = \case
  Public command -> case command of
    ReviseInstructions {} -> "revise-instructions"
    ReviseCriteria {} -> "revise-criteria"
    SetAssignments {} -> "set-assignments"
    RecordProgress {} -> "record-progress"
    RecordEvidence {} -> "record-evidence"
    SetNextAction {} -> "set-next-action"
    SetBlocked {} -> "set-blocked"
    ProposeCompletion {} -> "propose-completion"
    AcceptCompletion -> "accept-completion"
    CancelObjective -> "cancel"
    GrantMember {} -> "grant-member"
    RevokeMember {} -> "revoke-member"
    BindConversation {} -> "bind-conversation"
    LinkExternal {} -> "link-external"
  Internal ApplyAdaptiveDecision {} -> "adaptive-decision"
  Internal IngestCheckpoint {} -> "ingest-checkpoint"
  Internal ProjectCheckpoint {} -> "project-checkpoint"
  Internal RetainCoordination {} -> "retain-coordination"
  Internal TransferSessionOwnership {} -> "transfer-session-ownership"
  Internal TransferOwnership {} -> "transfer-ownership"

evidenceInputs :: Mutation -> [EvidenceInput]
evidenceInputs = \case
  Public (RecordEvidence _ input) -> [input]
  Internal (IngestCheckpoint _ _ inputs _) -> inputs
  Internal (ApplyAdaptiveDecision decision) -> [input | operation <- decision.operations, IntegrateResult _ input <- [operation.change]]
  _ -> []
