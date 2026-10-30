-- | Package-private admitted context. There is deliberately no JSON decoder.
module Shikigami.Objective.Authority where

import Shikigami.Objective.Types
import Shikigami.Prelude

data Access = Access
  { actor :: !AccessPrincipal,
    settings :: !ObjectiveSettings,
    expiresAt :: !UTCTime,
    checks :: ![(EvidenceInput, EvidenceVerification)],
    refusal :: !(Maybe ObjectiveError)
  }
  deriving stock (Generic)
