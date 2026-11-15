-- | The 'LocalOperator' adapter of the kernel authority port.
--
-- Under the local-operator tier the operator is the authority. A run's
-- actions are decided against the one grant resolved for its declaration and
-- repository: the pure 'decideLocalAction' policy approves exactly what was
-- granted, and 'localOperatorAuthority' adapts it to the port. A composition
-- installs it with 'Shikigami.Authority.recorded', so every decision,
-- refusals included, reaches the action record (ADR-124).
module Shikigami.Trust.LocalOperator.Authority
  ( LocalSelection (..),
    LocalDecision (..),
    RefusalReason (..),
    renderRefusalReason,
    decideLocalAction,
    localOperatorAuthority,
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Authority
import Shikigami.Capability.Overlay (CapabilityId, mkCapabilityId)
import Shikigami.Repository (repositoryIdText)
import Shikigami.Trust.LocalOperator.Grant (GrantDigest, LocalGrant, shortDigest)

-- | One run's view of its grant: the principals that may act for the agent
-- (its declared principal and its compatibility principal) and the grant.
data LocalSelection = LocalSelection
  { agent :: !AgentName,
    principals :: !(Set Principal),
    grant :: !LocalGrant
  }

data LocalDecision
  = Approved !GrantDigest
  | Refused !RefusalReason
  deriving stock (Eq, Show)

data RefusalReason
  = ForeignPrincipal
  | CapabilityNotGranted !Text
  | -- | No plan has granted this kind of action under the local operator yet.
    OutsideGrant !Text
  deriving stock (Eq, Show)

renderRefusalReason :: AgentName -> LocalGrant -> RefusalReason -> Text
renderRefusalReason agent grant = \case
  ForeignPrincipal -> "the principal does not act for " <> agentNameText agent
  CapabilityNotGranted capability -> capability <> " is not granted to " <> agentNameText agent <> " on " <> repositoryIdText grant.repository
  OutsideGrant tag -> tag <> " is not granted under the local operator"

-- | Approve exactly what was granted. Capability connections and tool calls
-- are approved for granted capabilities; every other kind of action is
-- outside the grant until the plan that owns it extends this policy (EP-2
-- coding agents, EP-3 declared tools, EP-8 M2 outputs and approvals).
decideLocalAction :: LocalSelection -> Principal -> Action -> LocalDecision
decideLocalAction LocalSelection {principals, grant} principal action
  | principal `Set.notMember` principals = Refused ForeignPrincipal
  | otherwise = case action of
      UseCapability _ target -> case mkCapabilityId (capabilityTargetId target) of
        Right capability | capability `Set.member` grantedCapabilities -> Approved grant.digest
        _ -> Refused (CapabilityNotGranted (capabilityTargetId target))
      EmitOutput {} -> Refused (OutsideGrant (actionTag action))
  where
    grantedCapabilities :: Set CapabilityId
    grantedCapabilities = grant.capabilities

-- | The port adapter. Allows carry the grant's short digest as their
-- reference; refusals are policy denials with a readable reason.
localOperatorAuthority :: LocalSelection -> Authority
localOperatorAuthority selection =
  authority DecidedByOperator \principal action ->
    pure case decideLocalAction selection principal action of
      Approved digest -> Right Decision {action, reference = "grant:" <> shortDigest digest, expiresAt = Nothing}
      Refused reason -> Left (PolicyDenied (renderRefusalReason selection.agent selection.grant reason))
