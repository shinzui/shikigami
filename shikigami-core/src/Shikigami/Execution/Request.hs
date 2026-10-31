-- | Declaration permission and inbound requests are distinct from decision slots.
module Shikigami.Execution.Request (ExecutionPolicy (..), ExecutionRequest (..), ExecutionContext (..)) where

import Baikai.ThinkingLevel (ThinkingLevel)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Dhall (FromDhall)
import Shikigami.Decision.ModelAlias (ModelAlias)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Prelude

data ExecutionPolicy = ExecutionPolicy
  { defaultAlias :: !ModelAlias,
    permittedAliases :: ![ModelAlias]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON, FromDhall)

-- | A user can require a declared alias/thinking setting and narrow the set
-- available to this assignment. Endpoints, credentials and vendor flags have
-- no representation here.
data ExecutionRequest = ExecutionRequest
  { alias :: !(Maybe ModelAlias),
    permittedAliases :: !(Maybe [ModelAlias]),
    thinking :: !(Maybe ThinkingLevel)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON ExecutionRequest where
  parseJSON = Aeson.withObject "ExecutionRequest" \fields -> do
    unless (all (`elem` ["alias", "permittedAliases", "thinking"]) (KeyMap.keys fields)) (fail "unsupported execution requirement")
    Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object fields)

-- | Continuing conversation context is pinned for its epoch and survives
-- generation rotation. An absent follow-up context never strips this authority.
data ExecutionContext = ExecutionContext
  { rootId :: !(Maybe ExecutionRootId),
    request :: !(Maybe ExecutionRequest),
    permittedAliases :: !(Maybe [ModelAlias])
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
