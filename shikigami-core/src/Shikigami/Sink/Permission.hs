-- | The C11 permission gate. A stub static allow-list keyed by agent name stands in
-- for a future @shinzui/shomei@ grant lookup; the @IO@-returning @checkGrant@ keeps the
-- exact signature EP-10 will keep when it swaps the body. A denied sink is recorded,
-- never crashes the run.
module Shikigami.Sink.Permission
  ( SinkKind (..),
    AgentIdentity (..),
    Denied (..),
    sinkKindText,
    defaultGrantTable,
    checkGrant,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

-- | The five sink kinds the gate distinguishes. @SChannelEgress@ is reserved for the
-- not-yet-added channel-egress @Sink@ variant (IR-3).
data SinkKind
  = SKawaDigest
  | SKizashiSignal
  | SReiAction
  | SDanwaConversation
  | SChannelEgress
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Who is asking. The name is the de-risking key; later the shomei-verified @sub@.
newtype AgentIdentity = AgentIdentity {agentName :: Text}
  deriving stock (Eq, Show)

-- | A permission denial carrying its reason.
newtype Denied = Denied {deniedReason :: Text}
  deriving stock (Eq, Show)

-- | A human label for a sink kind (for log lines and denial reasons).
sinkKindText :: SinkKind -> Text
sinkKindText = \case
  SKawaDigest -> "KawaDigest"
  SKizashiSignal -> "KizashiSignal"
  SReiAction -> "ReiAction"
  SDanwaConversation -> "DanwaConversation"
  SChannelEgress -> "ChannelEgress"

-- | The static allow-list. The sample agents are granted; an unknown agent (e.g.
-- @intruder@) has no grants and is denied every sink.
defaultGrantTable :: Map Text (Set SinkKind)
defaultGrantTable =
  Map.fromList
    [ ("heartbeat", Set.fromList [SKawaDigest, SKizashiSignal, SReiAction, SDanwaConversation]),
      ("triage-note", Set.fromList [SKizashiSignal, SReiAction]),
      ("stalled-intention", Set.fromList [SKizashiSignal]),
      ("at-risk-customer", Set.fromList [SKizashiSignal])
    ]

-- | Is this agent permitted this sink kind? @Right ()@ if granted, else
-- @Left (Denied reason)@. Stub now; EP-10 swaps the body for a shomei lookup.
checkGrant :: AgentIdentity -> SinkKind -> IO (Either Denied ())
checkGrant (AgentIdentity nm) kind =
  pure $ case Map.lookup nm defaultGrantTable of
    Just kinds
      | Set.member kind kinds -> Right ()
      | otherwise -> Left (Denied ("agent '" <> nm <> "' is not granted " <> sinkKindText kind))
    Nothing -> Left (Denied ("agent '" <> nm <> "' has no sink grants"))
