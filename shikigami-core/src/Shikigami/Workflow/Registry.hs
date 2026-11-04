-- | The complete service registry shared by production and restart qualification.
module Shikigami.Workflow.Registry (workflowRegistry) where

import Data.Map.Strict qualified as Map
import Keiro.Workflow.Resume (WorkflowRegistry)
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.App (AppEffects)
import Shikigami.Coordination.Workflow qualified as Adaptive
import Shikigami.Execution.Driver qualified as Execution
import Shikigami.WorkerSession.Workflow qualified as WorkerSession

-- | AgentRun's registry includes its durable Approval child. Conversation adds
-- conversation and execution add their families on the same Kioku effect row.
workflowRegistry :: Agent.AgentRunDeps -> Conversation.ConversationEnv -> WorkflowRegistry AppEffects
workflowRegistry agents conversations =
  Agent.agentRunRegistry agents
    `Map.union` Conversation.conversationRegistry conversations
    `Map.union` Execution.executionRegistry (Agent.executionRuntime agents)
    `Map.union` Adaptive.registry (Agent.adaptiveRuntime agents)
    `Map.union` WorkerSession.sessionRegistry (Agent.workerSessionRuntime agents)
