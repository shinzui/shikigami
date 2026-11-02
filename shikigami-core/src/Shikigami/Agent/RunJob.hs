-- | The IP-7 trigger→run contract: a fired trigger becomes a 'RunJob' on the
-- @shikigami_run_jobs@ pgmq queue, which the worker (EP-5) drains. Client-safe (no
-- hasql/effectful deps) so the enqueuer and the worker share it.
module Shikigami.Agent.RunJob
  ( TriggerKind (..),
    RunRouteKind (..),
    RunJob (..),
    runJobWorkflowId,
  )
where

import Data.Aeson (Value, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID
import Keiki.Shape (CanonicalTypeName (..))
import Keiro.Workflow.Types (WorkflowId (..), mkWorkflowId)
import Kioku.Id (SessionId)
import Shikigami.Agent.Delegate.Context (DelegationBudgetId)
import Shikigami.Agent.Delegate.Depth (DelegationDepth)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity (..))
import Shikigami.Agent.Run.Key (RunKey, runKeyText)
import Shikigami.Decision.ModelAlias (ModelAlias)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Execution.Request (ExecutionRequest)
import Shikigami.Objective.Reference (ObjectiveAssociation)
import Shikigami.Prelude hiding ((.=))

-- | Which trigger class produced the job.
data TriggerKind = TriggeredBySchedule | TriggeredByStream | TriggeredByEvent | TriggeredByDelegation
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Which orchestration path the producer meant. Separate from 'TriggerKind',
-- which records where the job came from for audit and tracing: an event trigger
-- can mean either a conversation turn or an ordinary agent run, so the trigger
-- class cannot stand in for the route.
data RunRouteKind
  = -- | Run the durable agent-run workflow.
    AgentWorkflowRoute
  | -- | Drive one turn of a danwa conversation. The trigger payload must decode
    -- as an addressed message; a payload that does not is a producer bug and
    -- dead-letters rather than falling back to the other workflow.
    ConversationWorkflowRoute
  | -- | Execute an already accepted operation/attempt; the payload grants no authority.
    ExecutionOperationRoute
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A request to run one declared agent, with the trigger occurrence and payload.
data RunJob = RunJob
  { agentName :: !AgentName,
    identity :: !AgentIdentity,
    triggerKind :: !TriggerKind,
    occurredAt :: !UTCTime,
    triggerPayload :: !Value,
    idempotencyKey :: !RunKey,
    parentSessionId :: !(Maybe SessionId),
    parentRunWorkflowId :: !(Maybe WorkflowId),
    delegationDepth :: !(Maybe DelegationDepth),
    lineage :: ![AgentName],
    executionRequest :: !(Maybe ExecutionRequest),
    executionPermissions :: !(Maybe [ModelAlias]),
    executionRootId :: !(Maybe ExecutionRootId),
    delegationBudgetId :: !(Maybe DelegationBudgetId),
    objective :: !(Maybe ObjectiveAssociation),
    routeKind :: !RunRouteKind
  }
  deriving stock (Eq, Show, Generic)

-- | The current journal value is complete. The queue adds its generated
-- versioned envelope at the transport boundary, never inside the workflow.
instance ToJSON RunJob where
  toJSON job =
    Aeson.object
      ( maybe [] (\value -> ["objective" .= value]) job.objective
          <> [ "agentName" .= job.agentName,
               "identity" .= job.identity,
               "triggerKind" .= job.triggerKind,
               "occurredAt" .= job.occurredAt,
               "triggerPayload" .= job.triggerPayload,
               "idempotencyKey" .= job.idempotencyKey,
               "parentSessionId" .= job.parentSessionId,
               "parentRunWorkflowId" .= fmap (.unWorkflowId) job.parentRunWorkflowId,
               "delegationDepth" .= job.delegationDepth,
               "lineage" .= job.lineage,
               "executionRequest" .= job.executionRequest,
               "executionPermissions" .= job.executionPermissions,
               "executionRootId" .= job.executionRootId,
               "delegationBudgetId" .= job.delegationBudgetId,
               "routeKind" .= job.routeKind
             ]
      )

instance FromJSON RunJob where
  parseJSON = Aeson.withObject "RunJob" \value -> do
    agentName <- value .: "agentName"
    identity <- value .: "identity"
    case identity of
      UnresolvedLegacyIdentity -> fail "run job requires an admitted identity"
      _ -> pure ()
    triggerKind <- value .: "triggerKind"
    occurredAt <- value .: "occurredAt"
    triggerPayload <- value .: "triggerPayload"
    idempotencyKey <- value .: "idempotencyKey"
    parentSessionId <- value .: "parentSessionId"
    parentRunWorkflowId <- value .: "parentRunWorkflowId" >>= traverse (either (fail . show) pure . mkWorkflowId)
    delegationDepth <- value .: "delegationDepth"
    lineage <- value .: "lineage"
    executionRequest <- value .: "executionRequest"
    executionPermissions <- value .: "executionPermissions"
    executionRootId <- value .: "executionRootId"
    delegationBudgetId <- value .: "delegationBudgetId"
    objective <- value .:? "objective"
    routeKind <- value .: "routeKind"
    pure RunJob {agentName, identity, triggerKind, occurredAt, triggerPayload, idempotencyKey, parentSessionId, parentRunWorkflowId, delegationDepth, lineage, delegationBudgetId, executionRootId, executionRequest, executionPermissions, objective, routeKind}

-- | Preserve valid natural workflow keys. Keys containing Keiro journal
-- separators become deterministic UUIDv5 technical identities; they are not
-- allocated entity IDs and must never be rebranded as TypeID-v7 values.
runJobWorkflowId :: RunJob -> WorkflowId
runJobWorkflowId job =
  case mkWorkflowId (runKeyText job.idempotencyKey) of
    Right workflowId -> workflowId
    Left _ -> WorkflowId (UUID.toText (UUID.generateNamed UUID.namespaceURL (nameBytes ("shikigami.agent-run:" <> runKeyText job.idempotencyKey))))

instance CanonicalTypeName TriggerKind where
  canonicalTypeName _ = "shikigami.TriggerKind.v1"

instance CanonicalTypeName RunRouteKind where
  canonicalTypeName _ = "shikigami.RunRouteKind.v1"
