module Shikigami.Agent.Workflow.Name
  ( agentRunWorkflowName,
  )
where

import Keiro.Workflow (WorkflowName (..))

agentRunWorkflowName :: WorkflowName
agentRunWorkflowName = WorkflowName "shikigami.agent-run"
