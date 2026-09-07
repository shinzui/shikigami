-- | Nominal scalar owned by the agent execution boundary.
module Shikigami.Agent.Name (AgentName (..), agentNameText) where

import Data.Aeson (FromJSON (..), ToJSON)
import Data.Text (Text)
import Data.Text qualified as Text

-- | Construction from trusted application values is explicit. Wire ingress
-- validates the scalar before it reaches the durable execution boundary.
newtype AgentName = AgentName Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

agentNameText :: AgentName -> Text
agentNameText (AgentName value) = value

instance FromJSON AgentName where
  parseJSON json = do
    value <- parseJSON json
    if not (Text.null value) then pure (AgentName value) else fail "agent name must not be empty"
