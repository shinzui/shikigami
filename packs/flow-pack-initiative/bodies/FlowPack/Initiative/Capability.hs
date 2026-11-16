{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

-- | The capability the proposing flow reaches the ledger through, and the one
-- decision it makes. Every operation is one journaled step with a static
-- @initiative-*@ name, installed by "FlowPack.Initiative.Runtime". What an
-- operation journals is a readable value rather than a sealed one: the sealed
-- candidate is re-derived from the journaled envelope, so a run never trusts
-- intake for it.
module FlowPack.Initiative.Capability
  ( Initiative (..),
    Opened (..),
    Resolution (..),
    AdmissionDecision (..),
    Funded (..),
    open,
    recordSkip,
    recordProposal,
    resolve,
    reserve,
    fund,
    launch,
    failAdmission,
    proposeWorkSlots,
    proposeWorkFlowName,
    proposeStep,
    proposeAlias,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Time (UTCTime)
import FlowPack.Initiative.Program.Assessment (AssessmentInput, AssessmentOutput, assessmentProgram)
import FlowPack.Initiative.Reservation (Reservation)
import FlowPack.Initiative.Settings (ObserverAllowance)
import FlowPack.Initiative.Types
import GHC.Generics (Generic)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity, AgentPrincipal)
import Shikigami.Agent.RunJob (RunJob)
import Shikigami.Decision.Contract (DecisionSlot)
import Shikigami.Decision.ModelAlias (ModelAlias, modelAliasFromNonEmpty)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Flow.Decision (DecisionAccounting (..), DecisionStep, decisionSite, decisionSlot, decisionStep)
import Shikigami.Flow.Sdk (DeclarationCoordinate, Dispatch (Dynamic), DispatchOf, Eff, Effect, declarationCoordinate, send, (:>))
import Shikigami.Objective.Types (ObjectiveId)
import Shikigami.Program.Decision (programRef)
import Shikigami.Repository (RepositoryId)

data Initiative :: Effect where
  Open :: Initiative m (Either SkipReason Opened)
  RecordSkip :: Opened -> SkipReason -> Initiative m ()
  RecordProposal :: Opened -> Assessment -> Initiative m (Either SkipReason ProposalView)
  Resolve :: Opened -> ProposalView -> Resolution -> Initiative m (Either RefusalKind ProposalView)
  ReserveAdmission :: Opened -> ProposalView -> Initiative m AdmissionDecision
  Fund :: Opened -> ProposalView -> Reservation -> ObjectiveId -> Initiative m (Either Text Funded)
  Launch :: ProposalView -> Funded -> Initiative m (Either Text Text)
  FailAdmission :: ProposalView -> RefusalKind -> Text -> Initiative m ()

type instance DispatchOf Initiative = Dynamic

-- | A candidate worth one evaluation, what the operator offers it, and who is
-- observing. Nothing here came from the observed text except the excerpt.
data Opened = Opened
  { candidate :: !Candidate,
    allowance :: !ObserverAllowance,
    repositories :: !(NonEmpty (RepositoryId, Text)),
    at :: !UTCTime,
    agent :: !AgentName,
    observer :: !AgentPrincipal,
    -- | What the assessment may choose: every class, or what covering policies permit.
    permitted :: !(NonEmpty ActionClass),
    -- | The standing policies this run may be admitted under, in install order.
    consulted :: ![StandingPolicyId]
  }

-- | The journaled outcome of trying to admit. A refusal is retained in bounded
-- words before the Flow falls back to a person, so nothing is dropped silently.
data AdmissionDecision = Admit !Reservation | HumanPath !(Maybe Text)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The coordinator's run, funded and not yet started.
data Funded = Funded
  { rootId :: !ExecutionRootId,
    job :: !RunJob,
    coordinatorIdentity :: !AgentIdentity
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Resolution
  = AcceptedWith !ObjectiveId
  | AdmittedUnder !ObjectiveId !StandingPolicyId
  | RejectedByPerson
  | ExpiredUnanswered
  | RefusedBecause !RefusalKind
  deriving stock (Eq, Show)

open :: (Initiative :> es) => Eff es (Either SkipReason Opened)
open = send Open

recordSkip :: (Initiative :> es) => Opened -> SkipReason -> Eff es ()
recordSkip opened reason = send (RecordSkip opened reason)

recordProposal :: (Initiative :> es) => Opened -> Assessment -> Eff es (Either SkipReason ProposalView)
recordProposal opened assessment = send (RecordProposal opened assessment)

resolve :: (Initiative :> es) => Opened -> ProposalView -> Resolution -> Eff es (Either RefusalKind ProposalView)
resolve opened proposal resolution = send (Resolve opened proposal resolution)

reserve :: (Initiative :> es) => Opened -> ProposalView -> Eff es AdmissionDecision
reserve opened proposal = send (ReserveAdmission opened proposal)

fund :: (Initiative :> es) => Opened -> ProposalView -> Reservation -> ObjectiveId -> Eff es (Either Text Funded)
fund opened proposal reservation objective = send (Fund opened proposal reservation objective)

launch :: (Initiative :> es) => ProposalView -> Funded -> Eff es (Either Text Text)
launch proposal funded = send (Launch proposal funded)

failAdmission :: (Initiative :> es) => ProposalView -> RefusalKind -> Text -> Eff es ()
failAdmission proposal kind detail = send (FailAdmission proposal kind detail)

proposeWorkFlowName :: DeclarationCoordinate "flow"
proposeWorkFlowName = declarationCoordinate "propose-work"

proposeWorkSlots :: [DecisionSlot]
proposeWorkSlots = [decisionSlot proposeStep [proposeAlias]]

-- | The one decision the flow makes: is this observed excerpt actionable, and
-- for which repository and action class. It journals
-- @decision-prepare-initiative-propose@ and @decision-result-initiative-propose@,
-- and is charged to the run's evaluation root.
proposeStep :: DecisionStep AssessmentInput AssessmentOutput
proposeStep = decisionStep (decisionSite "initiative-propose") RootAccountedCall (programRef assessmentProgram)

-- | The alias a proposing agent's declaration lists in @decisionModels@.
proposeAlias :: ModelAlias
proposeAlias = modelAliasFromNonEmpty ('p' :| "ropose")
