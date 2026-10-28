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
    enqueueAddressedRunWithKey,
    addressedRunJob,
    scheduleRunIdempotencyKey,
    enqueueScheduledRun,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Hasql.Pool (Pool, UsageError)
import Hasql.Pool qualified as Pool
import Hasql.Transaction qualified as Tx
import Keiro.PGMQ qualified as Job
import Pgmq (MessageBody (..), MessageId, QueueName, SendMessage (..), createQueue, parseQueueName, sendMessage)
import Pgmq.Hasql.Statements.Message qualified as PgmqStatements
import Shikigami.Activity (ActivityEnvelope (..))
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (AgentIdentity, compatibilityIdentity)
import Shikigami.Agent.Run.Key (RunKey (..))
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (..))
import Shikigami.Id.Name (nameBytes)
import Shikigami.Prelude
import Shikigami.RunJobs (encodeRunJob, queuePhysical, runJob)

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
  iso8601ParseM (Text.unpack envOccurredAt)

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
    { agentName = AgentName ((.name) decl),
      identity,
      triggerKind = TriggeredByStream,
      routeKind = AgentWorkflowRoute,
      occurredAt = resolvedOccurredAt,
      triggerPayload = toJSON env,
      idempotencyKey = RunKey ((.name) decl <> ":" <> envActivityId),
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [AgentName ((.name) decl)],
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
addressedRunKey :: Text -> Value -> Text
addressedRunKey agent payload =
  agent
    <> ":evt:"
    <> UUID.toText
      ( UUID.V5.generateNamed
          UUID.V5.namespaceURL
          (nameBytes (agent <> ":" <> Text.Encoding.decodeUtf8Lenient (LazyByteString.toStrict (Aeson.encode payload))))
      )

-- | Enqueue an addressed run with a caller-supplied stable idempotency key.
--
-- The route is a parameter rather than an inference: an event-triggered job can
-- mean either workflow, and only the caller knows which one it meant.
enqueueAddressedRunWithKey :: Pool -> AgentIdentity -> Text -> RunRouteKind -> Value -> Text -> IO (Either UsageError MessageId)
enqueueAddressedRunWithKey pool identity agent route payload key = do
  now <- getCurrentTime
  enqueueRunJob pool (addressedRunJob now identity agent route payload (RunKey key))

-- | The CLI and HTTP producers share this exact queue payload constructor.
addressedRunJob :: UTCTime -> AgentIdentity -> Text -> RunRouteKind -> Value -> RunKey -> RunJob
addressedRunJob now identity agent route payload key =
  RunJob
    { agentName = AgentName agent,
      identity,
      triggerKind = TriggeredByEvent,
      routeKind = route,
      occurredAt = now,
      triggerPayload = payload,
      idempotencyKey = key,
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [AgentName agent],
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

-- | Enqueue a schedule-triggered run for a deterministic due minute.
enqueueScheduledRun :: Pool -> AgentIdentity -> Text -> UTCTime -> IO (Either UsageError MessageId)
enqueueScheduledRun pool identity agent dueAt =
  enqueueRunJob
    pool
    RunJob
      { agentName = AgentName agent,
        identity,
        triggerKind = TriggeredBySchedule,
        routeKind = AgentWorkflowRoute,
        occurredAt = dueAt,
        triggerPayload =
          Aeson.object
            [ "kind" Aeson..= ("shikigami.schedule" :: Text),
              "agent" Aeson..= agent,
              "dueAt" Aeson..= dueAt
            ],
        idempotencyKey = RunKey (scheduleRunIdempotencyKey agent dueAt),
        parentSessionId = Nothing,
        parentRunWorkflowId = Nothing,
        delegationDepth = Nothing,
        lineage = [AgentName agent],
        executionRootId = Nothing,
        delegationBudgetId = Nothing
      }

-- | The producer and lifecycle-audit key for one deterministic cron tick.
scheduleRunIdempotencyKey :: Text -> UTCTime -> Text
scheduleRunIdempotencyKey agent dueAt =
  agent <> ":sched:" <> Text.pack (iso8601Show dueAt)
