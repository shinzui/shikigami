-- | The vocabulary of the C11 permission gate: denials and the pure
-- decision over a compiled-in allow-list. Grants are keyed by output kind.
--
-- This module deliberately knows nothing about a database. The gate that
-- production actually runs — reading @shikigami.sink_grants@ — lives in
-- "Shikigami.Sink.GrantStore", which imports this one. Keeping the direction
-- one-way is what lets 'checkGrantStatic' stay a pure function that tests can
-- call without a pool.
module Shikigami.Sink.Permission
  ( AgentIdentity (..),
    Denied (..),
    defaultGrantTable,
    checkGrantStatic,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Agent.Name (agentNameText, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (..), principalText)
import Shikigami.Authority (OutputKind, mkOutputKind, outputKindText)

-- | A permission denial carrying its reason.
newtype Denied = Denied {reason :: Text}
  deriving stock (Eq, Show)

-- | The static allow-list, by output kind (plan 135, M3). The sample agents
-- are granted; an unknown agent (e.g. @intruder@) has no grants and is
-- denied every output the gate covers.
--
-- This is not the gate: it is the seed data the @sink-grants@ migration
-- inserted (renamed to output kinds by @0052-output-kind-grants@), and the
-- fixture the dispatch tests inject.
defaultGrantTable :: Map AgentIdentity (Set OutputKind)
defaultGrantTable =
  Map.fromList
    [ (compatibilityName "heartbeat", kinds ["kawa.digest", "kizashi.signal", "rei.action", "danwa.conversation"]),
      (compatibilityName "danwa-heartbeat", kinds ["danwa.conversation"]),
      (compatibilityName "triage-note", kinds ["kizashi.signal", "rei.action"]),
      (compatibilityName "stalled-intention", kinds ["kizashi.signal"]),
      (compatibilityName "at-risk-customer", kinds ["kizashi.signal"])
    ]
  where
    kinds = Set.fromList . fmap (either (error . Text.unpack) id . mkOutputKind)

compatibilityName :: Text -> AgentIdentity
compatibilityName = either (error . show) CompatibilityIdentity . mkAgentName

-- | The pure decision over a compiled-in table. Kept separate from
-- 'Shikigami.Sink.GrantStore.checkGrant' so the static arm stays testable
-- without any IO.
checkGrantStatic :: Map AgentIdentity (Set OutputKind) -> AgentIdentity -> OutputKind -> Either Denied ()
checkGrantStatic table identity kind =
  case Map.lookup identity table of
    Just kinds
      | Set.member kind kinds -> Right ()
      | otherwise -> Left (Denied ("agent '" <> nm <> "' is not granted " <> outputKindText kind))
    Nothing -> Left (Denied ("agent '" <> nm <> "' has no sink grants"))
  where
    nm = case identity of
      VerifiedIdentity principal -> principalText principal
      CompatibilityIdentity agentName -> agentNameText agentName
      UnresolvedLegacyIdentity -> "unresolved-legacy"
