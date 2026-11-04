module Shikigami.Flow.AdaptiveDelivery (adaptiveDelivery) where

import Data.Aeson (Value)
import Effectful (Eff, (:>))
import Shikigami.Coordination.Capability (AdaptiveDelivery, deliver)
import Shikigami.Flow.Decision (Decision, pinnedDecisionPolicy)

adaptiveDelivery :: (AdaptiveDelivery :> es, Decision :> es) => Value -> Eff es Value
adaptiveDelivery request = do
  policy <- pinnedDecisionPolicy
  deliver policy request
