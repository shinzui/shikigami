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
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Aeson.Types qualified as Aeson
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Codec (Codec (..))
import Keiro.PGMQ (Job (..), JobCodec (..), JobDecodeError (..), queueRef)
import Keiro.PGMQ.Codec (keiroJobCodec)
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.Id (idText)
import Shikigami.Agent.Delegate.Context (DelegationBudgetId (..))
import Shikigami.Agent.Delegate.Depth (depthInt)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Agent.Run.Key (runKeyText)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (..))
import Shikigami.Execution.Identity (ExecutionRootId)
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
      jobPolicy = Policy.retryPolicy,
      jobOrdering = Policy.jobOrdering
    }

runJobCodec :: JobCodec RunJob
runJobCodec = keiroJobCodec domainCodec

-- The generated queue owns its closed structural fields. Version 2 of the
-- application codec wraps the opaque triggerPayload with resource metadata;
-- the v1 upcaster always supplies Nothing, even if an old input resembles this
-- wrapper. Journal values remain the unwrapped RunJob and default the new field.
domainCodec :: Codec RunJob
domainCodec =
  Codec
    { eventTypes = Codec.runJobsPayloadCodec.eventTypes,
      eventType = \job -> Codec.runJobsPayloadCodec.eventType (toMessage job),
      schemaVersion = 2,
      encode = Queue.encodeRunJobMessage . toMessage,
      decode = \_ value -> do
        message <- Queue.parseRunJobMessage value
        (root, input) <- parseValue (Aeson.withObject "RunInputV2" (\o -> (,) <$> o Aeson..: "executionRootId" <*> o Aeson..: "input")) message.triggerPayload
        let domain = Queue.encodeRunJobMessage message
        parseValue (Aeson.withObject "RunJob" (\o -> Aeson.parseJSON (Aeson.Object (KeyMap.insert "executionRootId" (toJSON (root :: Maybe ExecutionRootId)) (KeyMap.insert "triggerPayload" input o))))) domain,
      upcasters = [(1, \_ -> upcast)]
    }
  where
    upcast value = do
      message <- Queue.parseRunJobMessage value
      parseValue (Aeson.withObject "RunJobMessage" (\o -> pure (Aeson.Object (KeyMap.insert "triggerPayload" (Aeson.object ["executionRootId" Aeson..= Aeson.Null, "input" Aeson..= message.triggerPayload]) o)))) (Queue.encodeRunJobMessage message)

encodeRunJob :: RunJob -> Value
encodeRunJob = runJobCodec.encodeJob

decodeRunJob :: Value -> Either JobDecodeError RunJob
decodeRunJob = runJobCodec.decodeJob

toMessage :: RunJob -> Queue.RunJobMessage
toMessage job =
  Queue.RunJobMessage
    { agentName = agentNameText job.agentName,
      identity = toJSON job.identity,
      triggerKind = triggerText job.triggerKind,
      occurredAt = job.occurredAt,
      triggerPayload = Aeson.object ["executionRootId" Aeson..= job.executionRootId, "input" Aeson..= job.triggerPayload],
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

parseValue :: (Value -> Aeson.Parser a) -> Value -> Either Text a
parseValue parser = first Text.pack . parseEither parser
