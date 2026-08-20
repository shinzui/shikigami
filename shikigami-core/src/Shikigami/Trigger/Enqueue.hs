-- | The producer side of the IP-7 run-job contract: build a 'RunJob' from a fired
-- trigger and enqueue it onto the @shikigami_run_jobs@ pgmq queue. The worker (EP-5)
-- drains the same queue. Reuses a hasql 'Pool' (e.g. the kioku store's pool).
module Shikigami.Trigger.Enqueue
  ( runQueueName,
    runJobFromEnvelope,
    enqueueRunJobTx,
    ensureRunQueue,
    enqueueRunJob,
    enqueueAddressedRun,
    enqueueAddressedRunWithKey,
    enqueueScheduledRun,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Hasql.Pool (Pool, UsageError)
import Hasql.Pool qualified as Pool
import Hasql.Transaction qualified as Tx
import Pgmq (MessageBody (..), MessageId, QueueName, SendMessage (..), createQueue, parseQueueName, sendMessage)
import Pgmq.Hasql.Statements.Message qualified as PgmqStatements
import Shikigami.Activity (ActivityEnvelope (..))
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (..))
import Shikigami.Prelude

-- | The IP-7 queue name (shared with the worker).
runQueueName :: QueueName
runQueueName = case parseQueueName "shikigami_run_jobs" of
  Right q -> q
  Left e -> error ("invalid run-queue name: " <> show e)

-- | Build a stream-trigger run job from a matched agent + the matching envelope.
runJobFromEnvelope :: AgentDecl -> ActivityEnvelope -> RunJob
runJobFromEnvelope decl env =
  RunJob
    { agentName = name decl,
      triggerKind = TriggeredByStream,
      routeKind = AgentWorkflowRoute,
      occurredAt = fromMaybe epoch (iso8601ParseM (Text.unpack envOccurredAt)),
      triggerPayload = toJSON env,
      idempotencyKey = name decl <> ":" <> envActivityId,
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }
  where
    ActivityEnvelope {activityId = envActivityId, occurredAt = envOccurredAt} = env
    epoch = UTCTime (fromGregorian 1970 1 1) 0

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
        messageBody = MessageBody (toJSON job),
        delay = Nothing
      }
    PgmqStatements.sendMessage

-- | Reconcile the run-job queue before accepting trigger deliveries.
-- PGMQ queue creation is idempotent.
ensureRunQueue :: Pool -> IO (Either UsageError ())
ensureRunQueue pool = Pool.use pool (createQueue runQueueName)

-- | Enqueue a run job: ensure the queue exists (idempotent), then send. The pgmq
-- schema itself is installed by the @pgmq-schema@ migration (shikigami-migrations).
enqueueRunJob :: Pool -> RunJob -> IO (Either UsageError MessageId)
enqueueRunJob pool job =
  Pool.use pool $ do
    createQueue runQueueName -- idempotent
    sendMessage
      SendMessage
        { queueName = runQueueName,
          messageBody = MessageBody (toJSON job),
          delay = Nothing
        }

-- | Enqueue an addressed (event-trigger) run for a named agent with a payload.
enqueueAddressedRun :: Pool -> Text -> RunRouteKind -> Value -> IO (Either UsageError MessageId)
enqueueAddressedRun pool agent route payload = do
  now <- getCurrentTime
  enqueueAddressedRunWithKey pool agent route payload (agent <> ":evt:" <> Text.pack (iso8601Show now))

-- | Enqueue an addressed run with a caller-supplied stable idempotency key.
--
-- The route is a parameter rather than an inference: an event-triggered job can
-- mean either workflow, and only the caller knows which one it meant.
enqueueAddressedRunWithKey :: Pool -> Text -> RunRouteKind -> Value -> Text -> IO (Either UsageError MessageId)
enqueueAddressedRunWithKey pool agent route payload key = do
  now <- getCurrentTime
  enqueueRunJob
    pool
    RunJob
      { agentName = agent,
        triggerKind = TriggeredByEvent,
        routeKind = route,
        occurredAt = now,
        triggerPayload = payload,
        idempotencyKey = key,
        parentSessionId = Nothing,
        parentRunWorkflowId = Nothing,
        delegationDepth = Nothing
      }

-- | Enqueue a schedule-triggered run for a deterministic due minute.
enqueueScheduledRun :: Pool -> Text -> UTCTime -> IO (Either UsageError MessageId)
enqueueScheduledRun pool agent dueAt =
  enqueueRunJob
    pool
    RunJob
      { agentName = agent,
        triggerKind = TriggeredBySchedule,
        routeKind = AgentWorkflowRoute,
        occurredAt = dueAt,
        triggerPayload =
          Aeson.object
            [ "kind" Aeson..= ("shikigami.schedule" :: Text),
              "agent" Aeson..= agent,
              "dueAt" Aeson..= dueAt
            ],
        idempotencyKey = agent <> ":sched:" <> Text.pack (iso8601Show dueAt),
        parentSessionId = Nothing,
        parentRunWorkflowId = Nothing,
        delegationDepth = Nothing
      }
