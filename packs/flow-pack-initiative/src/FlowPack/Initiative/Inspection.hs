-- | What an operator reads about attention and admission: every configured
-- observer, every live policy and the pending count, with exhaustion explicit. It
-- reveals no excerpt or body, because the ledger stores none.
module FlowPack.Initiative.Inspection
  ( InspectionView (..),
    inspect,
    anyExhausted,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import FlowPack.Initiative.Ledger (ObserverUsageView (..), countPendingProposals, observerUsage)
import FlowPack.Initiative.Policy (PolicyRefusal, PolicyUsage (..), livePolicies, policyUsage)
import FlowPack.Initiative.Settings (InitiativeSettings (..))
import GHC.Generics (Generic)
import Hasql.Transaction (Transaction)

data InspectionView = InspectionView
  { observers :: ![ObserverUsageView],
    policies :: ![PolicyUsage],
    pendingProposals :: !Int,
    inspectedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

inspect :: Maybe InitiativeSettings -> UTCTime -> Transaction (Either PolicyRefusal InspectionView)
inspect settings now = do
  observers <- traverse (`observerUsage` now) (maybe [] (.observers) settings)
  pendingProposals <- countPendingProposals
  live <- livePolicies now
  case live of
    Left refusal -> pure (Left refusal)
    Right stored -> do
      policies <- traverse (policyUsage now) stored
      pure (Right InspectionView {observers, policies, pendingProposals, inspectedAt = now})

-- | A stopped state an operator's periodic check can alarm on.
anyExhausted :: InspectionView -> Bool
anyExhausted view = any (not . null . (.exhausted)) view.observers || any (not . null . (.exhausted)) view.policies
