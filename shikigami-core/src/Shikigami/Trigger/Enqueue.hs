-- | The producer side of the IP-7 run-job contract: build a 'RunJob' from a fired
-- trigger and enqueue it onto the @shikigami_run_jobs@ pgmq queue. The worker (EP-5)
-- drains the same queue. Reuses a hasql 'Pool' (e.g. the kioku store's pool).
module Shikigami.Trigger.Enqueue
  ( runQueueName,
    envelopeOccurredAt,
    runJobFromEnvelope,
    runJobFromEnvelopeWithIdentity,
    enqueueRunJobTx,
    ensureRunQueue,
    enqueueRunJob,
    addressedRunKey,
    addressedRunKeyWithKey,
    integrationRunKey,
    enqueueAddressedRun,
    enqueueAddressedRunWithKey,
    addressedRunJob,
    scheduleRunIdempotencyKey,
    enqueueScheduledRun,
  )
where

import Data.Aeson (Value, (.=))
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Hasql.Pool (Pool, UsageError)
import Hasql.Pool qualified as Pool
import Hasql.Transaction qualified as Tx
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.PGMQ qualified as Job
import Pgmq (MessageBody (..), MessageId, QueueName, SendMessage (..), createQueue, parseQueueName, sendMessage)
import Pgmq.Hasql.Statements.Message qualified as PgmqStatements
import Shikigami.Activity (ActivityEnvelope (..), activityCoordinateText)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity, compatibilityIdentity)
import Shikigami.Agent.Run.Key (RunKey, runKeyWithPrefix)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (..))
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Prelude hiding ((.=))
import Shikigami.RunJobs (encodeRunJob, queuePhysical, runJob)
import Shikigami.Trigger.RequestKey qualified as Addressed

-- | The IP-7 queue name (shared with the worker).
runQueueName :: QueueName
runQueueName = case parseQueueName queuePhysical of
  Right q -> q
  Left e -> error ("invalid run-queue name: " <> show e)

-- | When an envelope says it happened, if it says so in ISO-8601.
--
-- 'Nothing' is a producer bug, and the caller is expected to say so and
-- substitute its own clock. The previous behavior — falling back to
-- @1970-01-01T00:00:00Z@ inside 'runJobFromEnvelope' — silently backdated the
-- run by decades, which is the kind of quiet wrong answer this is a queue
-- contract to avoid: the run's kioku session and every memory it records sort
-- before every real one, and nothing anywhere says why.
envelopeOccurredAt :: ActivityEnvelope -> Maybe UTCTime
envelopeOccurredAt ActivityEnvelope {occurredAt = envOccurredAt} =
  iso8601ParseM (Text.unpack (activityCoordinateText envOccurredAt))

-- | Build a stream-trigger run job from a matched agent + the matching envelope.
--
-- The occurrence instant is a parameter because deciding it may need a clock and
-- a log line, and this function is called inside the inbox transaction. The
-- caller resolves it with 'envelopeOccurredAt' before the transaction opens —
-- the same shape @eventInboxHandler@ already uses with its @receivedAt@.
runJobFromEnvelope :: UTCTime -> AgentDecl -> ActivityEnvelope -> RunJob
runJobFromEnvelope resolvedOccurredAt decl =
  runJobFromEnvelopeWithIdentity resolvedOccurredAt (compatibilityIdentity ((.name) decl)) decl

runJobFromEnvelopeWithIdentity :: UTCTime -> AgentIdentity -> AgentDecl -> ActivityEnvelope -> RunJob
runJobFromEnvelopeWithIdentity resolvedOccurredAt identity decl env =
  RunJob
    { agentName = ((.name) decl),
      identity,
      triggerKind = TriggeredByStream,
      objective = Nothing,
      routeKind = AgentWorkflowRoute,
      occurredAt = resolvedOccurredAt,
      triggerPayload = toJSON env,
      idempotencyKey = runKeyWithPrefix ('s' :| "tream-run-v2:") (versionedDigest "shikigami.stream-run/2" (Aeson.object ["agent" .= decl.name, "activity" .= envActivityId])),
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [((.name) decl)],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }
  where
    ActivityEnvelope {activityId = envActivityId} = env

-- | Enqueue a run job inside a caller-owned Postgres transaction.
--
-- The queue must already exist; call 'ensureRunQueue' once at process startup.
-- Keeping queue creation out of this function lets an inbox row and its run-job
-- message commit or roll back as one database fact.
enqueueRunJobTx :: RunJob -> Tx.Transaction MessageId
enqueueRunJobTx job =
  Tx.statement
    SendMessage
      { queueName = runQueueName,
        messageBody = MessageBody (encodeRunJob job),
        delay = Nothing
      }
    PgmqStatements.sendMessage

-- | Reconcile the run-job queue before accepting trigger deliveries.
-- PGMQ queue creation is idempotent.
ensureRunQueue :: Pool -> IO (Either UsageError ())
ensureRunQueue pool = Pool.use pool do
  createQueue runQueueName
  createQueue runJob.jobQueue.dlqName

-- | Enqueue a run job.
--
-- The queue must already exist; call 'ensureRunQueue' once at process startup.
-- This used to reconcile the queue on every single send, which is a round trip
-- per message to answer a question that cannot change while the process runs.
enqueueRunJob :: Pool -> RunJob -> IO (Either UsageError MessageId)
enqueueRunJob pool job =
  Pool.use pool $
    sendMessage
      SendMessage
        { queueName = runQueueName,
          messageBody = MessageBody (encodeRunJob job),
          delay = Nothing
        }

-- | A stable idempotency key for one addressed run.
--
-- Derived from the agent and the payload, so two invocations for the same
-- logical event produce the same key and therefore one run. The key this
-- replaced was built from 'getCurrentTime', which made the addressed producer
-- the one producer in the runtime that could not deduplicate anything: retrying
-- @shikigami enqueue-run@ after a timeout ran the agent twice.
addressedRunKey :: AgentName -> RunRouteKind -> Value -> RunKey
addressedRunKey agent route payload =
  runKeyWithPrefix ('a' :| "ddressed-run-v2:") (versionedDigest "shikigami.addressed-run/2" (Aeson.object ["agent" .= agent, "route" .= route, "payload" .= payload]))

addressedRunKeyWithKey :: AgentName -> RunRouteKind -> Addressed.RequestKey -> RunKey
addressedRunKeyWithKey agent route key =
  runKeyWithPrefix ('a' :| "ddressed-run-v2:") (versionedDigest "shikigami.addressed-run/2" (Aeson.object ["agent" .= agent, "route" .= route, "key" .= key]))

-- | The native envelope owns its opaque message identity. Preserve it exactly
-- in its own field rather than interpreting it as a UUID or a delimiter word.
integrationRunKey :: AgentName -> RunRouteKind -> IntegrationEvent -> RunKey
integrationRunKey agent route event =
  runKeyWithPrefix ('e' :| "vent-run-v2:") (versionedDigest "shikigami.integration-run/2" (Aeson.object ["agent" .= agent, "route" .= route, "message" .= event.messageId]))

enqueueAddressedRun :: Pool -> AgentIdentity -> AgentName -> RunRouteKind -> Value -> IO (Either UsageError MessageId)
enqueueAddressedRun pool identity agent route payload = do
  now <- getCurrentTime
  enqueueRunJob pool (addressedRunJob now identity agent route payload (addressedRunKey agent route payload))

-- | The caller key stays distinct from the full scoped run coordinate.
enqueueAddressedRunWithKey :: Pool -> AgentIdentity -> AgentName -> RunRouteKind -> Value -> Addressed.RequestKey -> IO (Either UsageError MessageId)
enqueueAddressedRunWithKey pool identity agent route payload key = do
  now <- getCurrentTime
  enqueueRunJob pool (addressedRunJob now identity agent route payload (addressedRunKeyWithKey agent route key))

-- | The CLI and HTTP producers share this exact queue payload constructor.
addressedRunJob :: UTCTime -> AgentIdentity -> AgentName -> RunRouteKind -> Value -> RunKey -> RunJob
addressedRunJob now identity agent route payload key =
  RunJob
    { agentName = agent,
      identity,
      triggerKind = TriggeredByEvent,
      objective = Nothing,
      routeKind = route,
      occurredAt = now,
      triggerPayload = payload,
      idempotencyKey = key,
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [agent],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

-- | Enqueue a schedule-triggered run for a deterministic due minute.
enqueueScheduledRun :: Pool -> AgentIdentity -> AgentName -> UTCTime -> IO (Either UsageError MessageId)
enqueueScheduledRun pool identity agent dueAt =
  enqueueRunJob
    pool
    RunJob
      { agentName = agent,
        identity,
        triggerKind = TriggeredBySchedule,
        objective = Nothing,
        routeKind = AgentWorkflowRoute,
        occurredAt = dueAt,
        triggerPayload =
          Aeson.object
            [ "kind" .= ("shikigami.schedule" :: Text),
              "agent" .= agent,
              "dueAt" .= dueAt
            ],
        idempotencyKey = scheduleRunIdempotencyKey agent dueAt,
        parentSessionId = Nothing,
        parentRunWorkflowId = Nothing,
        delegationDepth = Nothing,
        lineage = [agent],
        executionRequest = Nothing,
        executionPermissions = Nothing,
        executionRootId = Nothing,
        delegationBudgetId = Nothing
      }

-- | The producer and lifecycle-audit key for one deterministic cron tick.
scheduleRunIdempotencyKey :: AgentName -> UTCTime -> RunKey
scheduleRunIdempotencyKey agent dueAt =
  runKeyWithPrefix ('s' :| "chedule-run-v2:") (versionedDigest "shikigami.scheduled-run/2" (Aeson.object ["agent" .= agent, "dueAt" .= dueAt]))
