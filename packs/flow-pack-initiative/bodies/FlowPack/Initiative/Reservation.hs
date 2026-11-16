-- | What a standing policy reserves for one covered proposal, as the flow
-- body and the journal carry it. The policy rows themselves, and the
-- transaction that takes a reservation, are "FlowPack.Initiative.Policy".
module FlowPack.Initiative.Reservation
  ( Reservation (..),
    PolicyDigest,
    policyDigest,
    policyDigestText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Text (Text)
import FlowPack.Initiative.Types (StandingPolicyId)
import GHC.Generics (Generic)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Execution.Resources (Envelope)

-- | The digest of the policy document a reservation was taken under. An
-- admission stays pinned to it when the policy is later revoked or replaced.
newtype PolicyDigest = PolicyDigest Text
  deriving stock (Eq, Ord, Show)

policyDigest :: Text -> PolicyDigest
policyDigest = PolicyDigest

policyDigestText :: PolicyDigest -> Text
policyDigestText (PolicyDigest value) = value

instance ToJSON PolicyDigest where toJSON = toJSON . policyDigestText

instance FromJSON PolicyDigest where
  parseJSON = withText "policy digest" (pure . PolicyDigest)

-- | What a covered proposal is funded and staffed with. It crosses the journal,
-- so it holds the coordinator's name; the interpreter resolves its identity.
data Reservation = Reservation
  { policyId :: !StandingPolicyId,
    digest :: !PolicyDigest,
    envelope :: !Envelope,
    coordinator :: !AgentName
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
