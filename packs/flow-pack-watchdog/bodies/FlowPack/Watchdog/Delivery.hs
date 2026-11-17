{-# LANGUAGE DataKinds #-}

-- | Advisory payloads and addresses from trusted metadata only.
module FlowPack.Watchdog.Delivery (address, renderNotice) where

import Data.Aeson (Value, object, (.=))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import FlowPack.Watchdog.Settings (DeliveryPolicy (..))
import FlowPack.Watchdog.Types (FindingView (..))
import Kikan.Shikigami.Binding.Outputs (DanwaTarget (..), inThread, toRecipient)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Flow.Sdk (AddressedOutput (..))
import Shikigami.Objective.Types (ConversationRef, ObjectiveId, conversationRefText)

-- | A finding on an objective that has a conversation is posted into it;
-- any other goes to the operator. Both destinations come from the trusted
-- delivery policy and the objective's own record, never from the finding.
address :: DeliveryPolicy -> Map ObjectiveId ConversationRef -> FindingView -> AddressedOutput
address policy conversations finding = case finding.objective >>= (`Map.lookup` conversations) of
  Just conversation -> AddressedOutput (inThread (DanwaTarget (declarationCoordinate (conversationRefText conversation)) Nothing) policy.conversationOutput) (renderNotice finding)
  Nothing -> AddressedOutput (toRecipient policy.operatorRecipient policy.operatorOutput) (renderNotice finding)

renderNotice :: FindingView -> Value
renderNotice finding = object ["finding" .= finding.findingId, "objective" .= finding.objective, "subject" .= finding.subject, "kind" .= finding.kind, "evidence" .= finding.evidence, "window" .= finding.window, "limit" .= finding.limit]
