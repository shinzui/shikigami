-- | The complete service registry shared by production and restart qualification.
module Shikigami.Workflow.Registry (workflowRegistry) where

import Data.Map.Strict qualified as Map
import Keiro.Workflow.Resume (WorkflowRegistry)
import Kioku.App (AppEffects)
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Workflow qualified as Agent

-- | AgentRun's registry includes its durable Approval child. Conversation adds
-- the third family without erasing the resource-aware Kioku effect row.
workflowRegistry :: Agent.AgentRunDeps -> Conversation.ConversationEnv -> WorkflowRegistry AppEffects
workflowRegistry agents conversations =
  Agent.agentRunRegistry agents `Map.union` Conversation.conversationRegistry conversations
