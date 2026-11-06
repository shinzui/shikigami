{-# LANGUAGE DataKinds #-}

-- | Advisory payloads and addresses from trusted metadata only.
module Shikigami.Watchdog.Delivery (address, renderNotice) where

import Data.Aeson (Value, object, (.=))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Objective.Types (ConversationRef, ObjectiveId, conversationRefText)
import Shikigami.Sink.Types (AddressedSignal (..), DanwaTarget (..), SignalAddress (..))
import Shikigami.Watchdog.Settings (DeliveryPolicy (..))
import Shikigami.Watchdog.Types (FindingView (..))

address :: DeliveryPolicy -> Map ObjectiveId ConversationRef -> FindingView -> AddressedSignal
address policy conversations finding = case finding.objective >>= (`Map.lookup` conversations) of
  Just conversation -> AddressedSignal (Conversation (DanwaTarget (declarationCoordinate (conversationRefText conversation)) Nothing)) policy.conversationSink (renderNotice finding)
  Nothing -> AddressedSignal (Recipient policy.operatorRecipient) policy.operatorSink (renderNotice finding)

renderNotice :: FindingView -> Value
renderNotice finding = object ["finding" .= finding.findingId, "objective" .= finding.objective, "subject" .= finding.subject, "kind" .= finding.kind, "evidence" .= finding.evidence, "window" .= finding.window, "limit" .= finding.limit]
