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

import Data.Aeson (Value, toJSON, (.:), (.:?), (.=))
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
import Shikigami.Agent.Delegate.Context (DelegationBudgetId, delegationBudgetIdText)
import Shikigami.Agent.Delegate.Depth (depthInt)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Agent.Run.Key (runKeyText)
import Shikigami.Agent.RunJob (RunJob (..))
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Execution.Request (ExecutionRequest)
import Shikigami.Objective.Reference (ObjectiveAssociation)
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

-- The generated queue owns the closed structural fields. The complete first-
-- release application payload adds current execution authority and input fields.
-- No historical codec or upcaster is admitted before the first deployment.
domainCodec :: Codec RunJob
domainCodec =
  Codec
    { eventTypes = Codec.runJobsPayloadCodec.eventTypes,
      eventType = \job -> Codec.runJobsPayloadCodec.eventType (toMessage job),
      schemaVersion = 1,
      encode = Queue.encodeRunJobMessage . toMessage,
      decode = \_ value -> do
        message <- Queue.parseRunJobMessage value
        (root, request, permissions, input, objective) <- parseValue (Aeson.withObject "RunInput" (\o -> (,,,,) <$> o .: "executionRootId" <*> o .: "executionRequest" <*> o .: "executionPermissions" <*> o .: "input" <*> o .:? "objective")) message.triggerPayload
        let domain = Queue.encodeRunJobMessage message
        parseValue (Aeson.withObject "RunJob" (\o -> Aeson.parseJSON (Aeson.Object (KeyMap.insert "objective" (toJSON (objective :: Maybe ObjectiveAssociation)) (KeyMap.insert "executionRootId" (toJSON (root :: Maybe ExecutionRootId)) (KeyMap.insert "executionRequest" (toJSON (request :: Maybe ExecutionRequest)) (KeyMap.insert "executionPermissions" (toJSON (permissions :: Maybe [Text])) (KeyMap.insert "triggerPayload" input o)))))))) domain,
      upcasters = []
    }

encodeRunJob :: RunJob -> Value
encodeRunJob = runJobCodec.encodeJob

decodeRunJob :: Value -> Either JobDecodeError RunJob
decodeRunJob = runJobCodec.decodeJob

toMessage :: RunJob -> Queue.RunJobMessage
toMessage job =
  Queue.RunJobMessage
    { agentName = agentNameText job.agentName,
      identity = toJSON job.identity,
      triggerKind = job.triggerKind,
      occurredAt = job.occurredAt,
      triggerPayload = Aeson.object (maybe [] (\value -> ["objective" .= value]) job.objective <> ["executionRootId" .= job.executionRootId, "executionRequest" .= job.executionRequest, "executionPermissions" .= job.executionPermissions, "input" .= job.triggerPayload]),
      idempotencyKey = runKeyText job.idempotencyKey,
      parentSessionId = idText <$> job.parentSessionId,
      parentRunWorkflowId = (.unWorkflowId) <$> job.parentRunWorkflowId,
      delegationDepth = depthInt <$> job.delegationDepth,
      lineage = agentNameText <$> job.lineage,
      delegationBudgetId = budgetText <$> job.delegationBudgetId,
      routeKind = job.routeKind
    }

budgetText :: DelegationBudgetId -> Text
budgetText = delegationBudgetIdText

parseValue :: (Value -> Aeson.Parser a) -> Value -> Either Text a
parseValue parser = first Text.pack . parseEither parser
