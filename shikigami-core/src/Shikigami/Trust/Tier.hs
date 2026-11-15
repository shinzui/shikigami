-- | Which trust tier a process composes.
--
-- A tier selects who decides a run's external actions and how its processes
-- are contained. It never switches the kernel's guarantees off: every action
-- still has a principal, is decided by exactly one authority and is recorded
-- (ADR-123, ADR-124). Use-case code never matches on a tier; only composition
-- roots do.
module Shikigami.Trust.Tier
  ( TrustTier (..),
    parseTrustTier,
    trustTierText,
    trustTierLabel,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Record (TierLabel, mkTierLabel)

data TrustTier
  = -- | The operator, on their own machine, is the authority.
    LocalOperator
  | -- | The authority selected by @authorization.actions.mode@ under the
    -- composition's containment, as each executable does today.
    Contained
  | -- | 'Contained' with a configured service authority required.
    MultiTenant
  deriving stock (Eq, Ord, Show, Enum, Bounded)

parseTrustTier :: Text -> Either Text TrustTier
parseTrustTier = \case
  "local-operator" -> Right LocalOperator
  "contained" -> Right Contained
  "multi-tenant" -> Right MultiTenant
  other -> Left ("unknown trust tier " <> Text.pack (show other) <> "; expected local-operator, contained or multi-tenant")

trustTierText :: TrustTier -> Text
trustTierText = \case
  LocalOperator -> "local-operator"
  Contained -> "contained"
  MultiTenant -> "multi-tenant"

-- | The label recorded on every action record event of this tier.
trustTierLabel :: TrustTier -> TierLabel
trustTierLabel tier = either (error . Text.unpack) id (mkTierLabel (trustTierText tier))
