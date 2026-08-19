-- | The agent-run workflow's durable name.
--
-- The literal lives in @domain\/shikigami-agent-run.keiro@ and reaches Haskell
-- through the generated
-- "Shikigami.AgentRun.Generated.WorkflowRuntime". This module re-exports it so
-- the rest of the tree keeps one import and so a rename has exactly one place
-- to happen: the specification. Renaming it there is gated by
-- @keiro-dsl diff@, which is the point of
-- @docs\/plans\/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md@.
module Shikigami.Agent.Workflow.Name
  ( agentRunWorkflowName,
  )
where

import Keiro.Workflow (WorkflowName)
import Shikigami.AgentRun.Generated.WorkflowRuntime qualified as Generated

agentRunWorkflowName :: WorkflowName
agentRunWorkflowName = Generated.workflowName
