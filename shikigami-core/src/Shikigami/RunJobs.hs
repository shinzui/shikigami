-- | The executable generated run queue contract shared by every producer and
-- the worker. Generated wire values are validated before entering the domain.
module Shikigami.RunJobs
  ( runJob,
    runJobCodec,
    encodeRunJob,
    decodeRunJob,
    queueProvision,
    jobTuningFor,
    queuePhysical,
    queueTable,
  )
where

import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.PGMQ (Job (..), JobCodec (..), JobDecodeError (..), queueRef)
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.Id (idText)
import Shikigami.Agent.Delegate.Context (DelegationBudgetId (..))
import Shikigami.Agent.Delegate.Depth (depthInt)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Agent.Run.Key (runKeyText)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (..))
import Shikigami.RunJobs.Generated.Queue (queuePhysical, queueTable)
import Shikigami.RunJobs.Generated.Queue qualified as Queue
import Shikigami.RunJobs.Generated.QueueCodec qualified as Codec
import Shikigami.RunJobs.Generated.QueuePolicy (jobTuningFor, queueProvision)
import Shikigami.RunJobs.Generated.QueuePolicy qualified as Policy

runJob :: Job RunJob
runJob =
  Job
    { jobName = queuePhysical,
      jobQueue = queueRef queuePhysical,
      jobCodec = runJobCodec,
      jobPolicy = Policy.retryPolicy
    }

runJobCodec :: JobCodec RunJob
runJobCodec = JobCodec {encodeJob = encodeRunJob, decodeJob = decodeRunJob}

encodeRunJob :: RunJob -> Value
encodeRunJob = Codec.runJobsJobCodec.encodeJob . toMessage

decodeRunJob :: Value -> Either JobDecodeError RunJob
decodeRunJob value = do
  message <- Codec.runJobsJobCodec.decodeJob value
  first (JobPayloadMalformed . Text.pack) (parseEither Aeson.parseJSON (Queue.encodeRunJobMessage message))

toMessage :: RunJob -> Queue.RunJobMessage
toMessage job =
  Queue.RunJobMessage
    { agentName = agentNameText job.agentName,
      identity = toJSON job.identity,
      triggerKind = triggerText job.triggerKind,
      occurredAt = job.occurredAt,
      triggerPayload = job.triggerPayload,
      idempotencyKey = runKeyText job.idempotencyKey,
      parentSessionId = idText <$> job.parentSessionId,
      parentRunWorkflowId = (.unWorkflowId) <$> job.parentRunWorkflowId,
      delegationDepth = depthInt <$> job.delegationDepth,
      lineage = agentNameText <$> job.lineage,
      delegationBudgetId = budgetText <$> job.delegationBudgetId,
      routeKind = routeText job.routeKind
    }

triggerText :: TriggerKind -> Text
triggerText = \case
  TriggeredBySchedule -> "TriggeredBySchedule"
  TriggeredByStream -> "TriggeredByStream"
  TriggeredByEvent -> "TriggeredByEvent"
  TriggeredByDelegation -> "TriggeredByDelegation"

routeText :: RunRouteKind -> Text
routeText = \case
  AgentWorkflowRoute -> "AgentWorkflowRoute"
  ConversationWorkflowRoute -> "ConversationWorkflowRoute"

budgetText :: DelegationBudgetId -> Text
budgetText (DelegationBudgetId value) = value
