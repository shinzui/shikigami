module Shikigami.Agent.RunFailure
  ( AgentRunFailure (..),
    agentRunFailureDetail,
  )
where

import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Shikigami.Prelude hiding ((.=))

-- | Why an agent run completed without a result. This value is the durable
-- left-hand side of an agent-run workflow result, including delegated runs.
data AgentRunFailure
  = PermanentAgentRunFailure !Text
  deriving stock (Eq, Show, Generic)

agentRunFailureDetail :: AgentRunFailure -> Text
agentRunFailureDetail = \case
  PermanentAgentRunFailure detail -> detail

-- Keep the current permanent-failure encoding explicit after retiring the
-- unused legacy constructor. A transient failure is never journaled here.
instance ToJSON AgentRunFailure where
  toJSON (PermanentAgentRunFailure detail) =
    Aeson.object
      ["tag" .= ("PermanentAgentRunFailure" :: Text), "contents" .= detail]

instance FromJSON AgentRunFailure where
  parseJSON = Aeson.withObject "AgentRunFailure" \value -> do
    tag <- value .: "tag"
    if tag == ("PermanentAgentRunFailure" :: Text)
      then PermanentAgentRunFailure <$> value .: "contents"
      else fail "unknown agent-run failure"
