-- | The IP-7 trigger→run contract: a fired trigger becomes a 'RunJob' on the
-- @shikigami_run_jobs@ pgmq queue, which the worker (EP-5) drains. Client-safe (no
-- hasql/effectful deps) so the enqueuer and the worker share it.
module Shikigami.Agent.RunJob
  ( TriggerKind (..),
    RunRouteKind (..),
    RunJob (..),
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Shikigami.Agent.Delegate.Context (DelegationBudgetId)
import Shikigami.Agent.Principal (AgentIdentity (..))
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
  | -- | No producer sets this. It is what a job enqueued before the
    -- discriminator existed decodes to, and it is handled by reproducing the
    -- old duck-typed decision. Delete it once the queue has drained and
    -- @worker.job.route_inferred@ has stopped appearing.
    InferredLegacyRoute
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A request to run one declared agent, with the trigger occurrence and payload.
data RunJob = RunJob
  { agentName :: !Text,
    identity :: !AgentIdentity,
    triggerKind :: !TriggerKind,
    occurredAt :: !UTCTime,
    triggerPayload :: !Value,
    idempotencyKey :: !Text,
    parentSessionId :: !(Maybe Text),
    parentRunWorkflowId :: !(Maybe Text),
    delegationDepth :: !(Maybe Int),
    lineage :: ![Text],
    delegationBudgetId :: !(Maybe DelegationBudgetId),
    routeKind :: !RunRouteKind
  }
  deriving stock (Eq, Show, Generic)

-- | A run job crosses two durable boundaries — the @shikigami_run_jobs@ queue and
-- the workflow journal, where it is the recorded result of the @ingest-job@ step.
-- Per ADR 0011, an additive field must leave the previous bytes untouched when it
-- holds its compatibility default, so 'InferredLegacyRoute' emits no key at all
-- and a queued or journaled job written before the discriminator existed encodes
-- and decodes exactly as it did.
instance ToJSON RunJob where
  toJSON RunJob {agentName, identity, triggerKind, occurredAt, triggerPayload, idempotencyKey, parentSessionId, parentRunWorkflowId, delegationDepth, lineage, delegationBudgetId, routeKind} =
    Aeson.object
      ( [ "agentName" Aeson..= agentName,
          "triggerKind" Aeson..= triggerKind,
          "occurredAt" Aeson..= occurredAt,
          "triggerPayload" Aeson..= triggerPayload,
          "idempotencyKey" Aeson..= idempotencyKey,
          "parentSessionId" Aeson..= parentSessionId,
          "parentRunWorkflowId" Aeson..= parentRunWorkflowId,
          "delegationDepth" Aeson..= delegationDepth
        ]
          <> ["identity" Aeson..= identity | identity /= UnresolvedLegacyIdentity]
          <> ["lineage" Aeson..= lineage | not (null lineage)]
          <> maybe [] (\budgetId -> ["delegationBudgetId" Aeson..= budgetId]) delegationBudgetId
          <> ["routeKind" Aeson..= routeKind | routeKind /= InferredLegacyRoute]
      )

-- | A missing @routeKind@ decodes to 'InferredLegacyRoute', which the worker
-- handles by reproducing the pre-discriminator decision rather than assuming a
-- route nobody declared.
instance FromJSON RunJob where
  parseJSON = Aeson.withObject "RunJob" \value -> do
    agentName <- value Aeson..: "agentName"
    identity <- value Aeson..:? "identity" Aeson..!= UnresolvedLegacyIdentity
    triggerKind <- value Aeson..: "triggerKind"
    occurredAt <- value Aeson..: "occurredAt"
    triggerPayload <- value Aeson..: "triggerPayload"
    idempotencyKey <- value Aeson..: "idempotencyKey"
    parentSessionId <- value Aeson..:? "parentSessionId"
    parentRunWorkflowId <- value Aeson..:? "parentRunWorkflowId"
    delegationDepth <- value Aeson..:? "delegationDepth"
    lineage <- value Aeson..:? "lineage" Aeson..!= []
    delegationBudgetId <- value Aeson..:? "delegationBudgetId"
    routeKind <- value Aeson..:? "routeKind" Aeson..!= InferredLegacyRoute
    pure RunJob {agentName, identity, triggerKind, occurredAt, triggerPayload, idempotencyKey, parentSessionId, parentRunWorkflowId, delegationDepth, lineage, delegationBudgetId, routeKind}
