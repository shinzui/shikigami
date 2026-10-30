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

import Data.Aeson (Value)
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
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Execution.Request (ExecutionRequest)
import Shikigami.Id.Name (nameBytes)
import Shikigami.Prelude

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
    executionPermissions :: !(Maybe [Text]),
    executionRootId :: !(Maybe ExecutionRootId),
    delegationBudgetId :: !(Maybe DelegationBudgetId),
    routeKind :: !RunRouteKind
  }
  deriving stock (Eq, Show, Generic)

-- | The current journal value is complete. The queue adds its generated
-- versioned envelope at the transport boundary, never inside the workflow.
instance ToJSON RunJob where
  toJSON job =
    Aeson.object
      [ "agentName" Aeson..= job.agentName,
        "identity" Aeson..= job.identity,
        "triggerKind" Aeson..= job.triggerKind,
        "occurredAt" Aeson..= job.occurredAt,
        "triggerPayload" Aeson..= job.triggerPayload,
        "idempotencyKey" Aeson..= job.idempotencyKey,
        "parentSessionId" Aeson..= job.parentSessionId,
        "parentRunWorkflowId" Aeson..= fmap (.unWorkflowId) job.parentRunWorkflowId,
        "delegationDepth" Aeson..= job.delegationDepth,
        "lineage" Aeson..= job.lineage,
        "executionRequest" Aeson..= job.executionRequest,
        "executionPermissions" Aeson..= job.executionPermissions,
        "executionRootId" Aeson..= job.executionRootId,
        "delegationBudgetId" Aeson..= job.delegationBudgetId,
        "routeKind" Aeson..= job.routeKind
      ]

instance FromJSON RunJob where
  parseJSON = Aeson.withObject "RunJob" \value -> do
    agentName <- value Aeson..: "agentName"
    identity <- value Aeson..: "identity"
    case identity of
      UnresolvedLegacyIdentity -> fail "run job requires an admitted identity"
      _ -> pure ()
    triggerKind <- value Aeson..: "triggerKind"
    occurredAt <- value Aeson..: "occurredAt"
    triggerPayload <- value Aeson..: "triggerPayload"
    idempotencyKey <- value Aeson..: "idempotencyKey"
    parentSessionId <- value Aeson..: "parentSessionId"
    parentRunWorkflowId <- value Aeson..: "parentRunWorkflowId" >>= traverse (either (fail . show) pure . mkWorkflowId)
    delegationDepth <- value Aeson..: "delegationDepth"
    lineage <- value Aeson..: "lineage"
    executionRequest <- value Aeson..: "executionRequest"
    executionPermissions <- value Aeson..: "executionPermissions"
    executionRootId <- value Aeson..: "executionRootId"
    delegationBudgetId <- value Aeson..: "delegationBudgetId"
    routeKind <- value Aeson..: "routeKind"
    pure RunJob {agentName, identity, triggerKind, occurredAt, triggerPayload, idempotencyKey, parentSessionId, parentRunWorkflowId, delegationDepth, lineage, delegationBudgetId, executionRootId, executionRequest, executionPermissions, routeKind}

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
