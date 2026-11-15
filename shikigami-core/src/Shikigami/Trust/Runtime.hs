-- | Per-run port resolution for a trust tier.
--
-- A process builds one 'TierComposition'. A worker serves many agents and a
-- playbook step may select another repository than the step before it, so
-- the ports are resolved per run and per repository: 'resolve' turns a
-- 'RunSubject' into the 'TierRuntime' that run uses, or a 'TierRefusal'
-- before anything is enqueued or a model is called. A later plan that adds a
-- tier-dependent behavior adds a field to 'TierRuntime'.
module Shikigami.Trust.Runtime
  ( RunSubject (..),
    TierRuntime (..),
    TierComposition (..),
    TierRefusal (..),
    renderTierRefusal,
  )
where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Workflow (WorkflowId)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Authority (Authority, Principal)
import Shikigami.Capability.Provider (CapabilityRuntime)
import Shikigami.Record (ActionRecord)
import Shikigami.Trust.LocalOperator.Approvals (ApprovalsError, RepositorySelector, renderApprovalsError)
import Shikigami.Trust.LocalOperator.Grant (GrantRefusal, LocalGrant, renderGrantRefusal)
import Shikigami.Trust.Tier (TrustTier, trustTierText)

-- | What a run is: the declaration, the principal it acts as, its run (absent
-- for a database-free one-off) and the repository it works in, when the
-- caller names one.
data RunSubject = RunSubject
  { agent :: !AgentDecl,
    principal :: !Principal,
    run :: !(Maybe WorkflowId),
    repository :: !(Maybe RepositorySelector)
  }

-- | The ports resolved for one run and one repository. The authority is
-- already installed over the record and scoped to the run.
data TierRuntime = TierRuntime
  { tier :: !TrustTier,
    authority :: !Authority,
    record :: !ActionRecord,
    capabilities :: !CapabilityRuntime,
    -- | The grant the run executes under, for tiers that have one.
    grant :: !(Maybe LocalGrant)
  }

data TierComposition = TierComposition
  { tier :: !TrustTier,
    resolve :: !(RunSubject -> IO (Either TierRefusal TierRuntime))
  }

data TierRefusal
  = -- | Nothing granted this declaration on this repository.
    NoGrant !GrantRefusal
  | RepositoryUnavailable !ApprovalsError
  | -- | The declaration lists outputs this composition cannot deliver.
    OutputsUnavailable !(NonEmpty Text)
  | -- | This executable does not compose the tier (for example
    -- @local-operator@ in @shikigami-worker@ until EP-2).
    TierUnsupportedHere !TrustTier !Text
  | -- | The composition itself could not be built for this run.
    CompositionFailed !Text

renderTierRefusal :: TierRefusal -> Text
renderTierRefusal = \case
  NoGrant refusal -> renderGrantRefusal refusal
  RepositoryUnavailable problem -> renderApprovalsError problem
  OutputsUnavailable kinds ->
    "the declaration lists outputs this composition cannot deliver: " <> Text.intercalate ", " (foldr (:) [] kinds)
  TierUnsupportedHere tier detail -> trustTierText tier <> " is not composed here: " <> detail
  CompositionFailed detail -> detail
