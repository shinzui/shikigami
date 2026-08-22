module Shikigami.Agent.RunFailure
  ( AgentRunFailure (..),
    agentRunFailureDetail,
  )
where

import Shikigami.Prelude

-- | Why an agent run completed without a result. This value is the durable
-- left-hand side of an agent-run workflow result, including delegated runs.
data AgentRunFailure
  = LegacyBehaviorFailure !Text
  | PermanentAgentRunFailure !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

agentRunFailureDetail :: AgentRunFailure -> Text
agentRunFailureDetail = \case
  LegacyBehaviorFailure detail -> detail
  PermanentAgentRunFailure detail -> detail
