-- | Assignment children are keyed by the retained session, rather than the
-- coordinator's current workflow generation or epoch.
module Shikigami.WorkerSession.Identity
  ( sessionWorkflowId,
    assignmentDelegationKey,
    assignmentChildWorkflowId,
  )
where

import Keiro.Workflow.Types (WorkflowId (..))
import Shikigami.Agent.Delegate (delegatedWorkflowId)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Prelude
import Shikigami.WorkerSession.Types (AssignmentId (..), WorkerSessionId (..))

sessionWorkflowId :: WorkerSessionId -> WorkflowId
sessionWorkflowId session = WorkflowId session.value

assignmentDelegationKey :: AssignmentId -> Text
assignmentDelegationKey assignment = assignment.value

assignmentChildWorkflowId :: WorkerSessionId -> AgentName -> AssignmentId -> WorkflowId
assignmentChildWorkflowId session target assignment =
  delegatedWorkflowId (sessionWorkflowId session) (agentNameText target) (assignmentDelegationKey assignment)
