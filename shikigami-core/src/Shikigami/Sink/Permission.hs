-- | The vocabulary of the C11 permission gate: sink kinds,
-- denials, and the pure decision over a compiled-in allow-list.
--
-- This module deliberately knows nothing about a database. The gate that
-- production actually runs — reading @shikigami.sink_grants@ — lives in
-- "Shikigami.Sink.GrantStore", which imports this one. Keeping the direction
-- one-way is what lets 'checkGrantStatic' stay a pure function that tests can
-- call without a pool.
module Shikigami.Sink.Permission
  ( SinkKind (..),
    AgentIdentity (..),
    Denied (..),
    sinkKindText,
    parseSinkKind,
    defaultGrantTable,
    checkGrantStatic,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikigami.Agent.Name (agentNameText, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (..), principalText)
import Shikigami.Prelude (FromJSON, ToJSON)

-- | The five sink kinds the gate distinguishes. @SChannelEgress@ is reserved for the
-- not-yet-added channel-egress @Sink@ variant (IR-3).
data SinkKind
  = SKawaDigest
  | SKizashiSignal
  | SReiAction
  | SDanwaConversation
  | SChannelEgress
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A permission denial carrying its reason.
newtype Denied = Denied {reason :: Text}
  deriving stock (Eq, Show)

-- | Read a sink kind back from the label 'sinkKindText' renders. Used by the
-- operator CLI, which takes a kind as an argument, and by nothing on the hot
-- path.
parseSinkKind :: Text -> Maybe SinkKind
parseSinkKind = \case
  "KawaDigest" -> Just SKawaDigest
  "KizashiSignal" -> Just SKizashiSignal
  "ReiAction" -> Just SReiAction
  "DanwaConversation" -> Just SDanwaConversation
  "ChannelEgress" -> Just SChannelEgress
  _ -> Nothing

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
--
-- This is no longer the gate: it is the seed data the @sink-grants@ migration
-- inserts, and the fixture the dispatch tests inject. Changing it changes
-- neither a running deployment nor a fresh database.
defaultGrantTable :: Map AgentIdentity (Set SinkKind)
defaultGrantTable =
  Map.fromList
    [ (compatibilityName "heartbeat", Set.fromList [SKawaDigest, SKizashiSignal, SReiAction, SDanwaConversation]),
      (compatibilityName "danwa-heartbeat", Set.fromList [SDanwaConversation]),
      (compatibilityName "triage-note", Set.fromList [SKizashiSignal, SReiAction]),
      (compatibilityName "stalled-intention", Set.fromList [SKizashiSignal]),
      (compatibilityName "at-risk-customer", Set.fromList [SKizashiSignal])
    ]

compatibilityName :: Text -> AgentIdentity
compatibilityName = either (error . show) CompatibilityIdentity . mkAgentName

-- | The pure decision over a compiled-in table. Kept separate from 'checkGrant'
-- so the static arm stays testable without any IO, exactly as the original stub
-- was.
checkGrantStatic :: Map AgentIdentity (Set SinkKind) -> AgentIdentity -> SinkKind -> Either Denied ()
checkGrantStatic table identity kind =
  case Map.lookup identity table of
    Just kinds
      | Set.member kind kinds -> Right ()
      | otherwise -> Left (Denied ("agent '" <> nm <> "' is not granted " <> sinkKindText kind))
    Nothing -> Left (Denied ("agent '" <> nm <> "' has no sink grants"))
  where
    nm = case identity of
      VerifiedIdentity principal -> principalText principal
      CompatibilityIdentity agentName -> agentNameText agentName
      UnresolvedLegacyIdentity -> "unresolved-legacy"
