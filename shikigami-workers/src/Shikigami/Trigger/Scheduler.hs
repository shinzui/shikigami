module Shikigami.Trigger.Scheduler
  ( SchedulerEnv (..),
    scheduleTimerKind,
    scheduleTimerPayload,
    parseSchedulePayload,
    scheduleTimerId,
    armNextRun,
    scheduleFireAction,
    shikigamiTimerFallback,
    runSchedulerTimerWorker,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Hasql.Pool (Pool)
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow (..), scheduleTimerOnceTx)
import Keiro.Workflow.Sleep (runWorkflowTimerWorker)
import Kioku.App (AppEnv (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..))
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Prelude
import Shikigami.Trigger.Enqueue (enqueueScheduledRun)
import Shikigami.Trigger.Schedule (CronSchedule, nextDue)

data SchedulerEnv = SchedulerEnv
  { pool :: !Pool,
    schedules :: !(Map Text CronSchedule)
  }

data ScheduleTimerPayload = ScheduleTimerPayload
  { kind :: !Text,
    agent :: !Text,
    dueAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

scheduleTimerKind :: Text
scheduleTimerKind = "shikigami.schedule"

scheduleTimerPayload :: Text -> UTCTime -> Value
scheduleTimerPayload agent dueAt =
  Aeson.toJSON ScheduleTimerPayload {kind = scheduleTimerKind, agent, dueAt}

parseSchedulePayload :: Value -> Maybe (Text, UTCTime)
parseSchedulePayload value = do
  ScheduleTimerPayload {kind, agent, dueAt} <- parseMaybe Aeson.parseJSON value
  if kind == scheduleTimerKind
    then Just (agent, dueAt)
    else Nothing

scheduleTimerId :: Text -> UTCTime -> TimerId
scheduleTimerId agent dueAt =
  TimerId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      fmap (fromIntegral . fromEnum) $
        Text.unpack $
          Text.intercalate ":" ["shikigami", "schedule", agent, Text.pack (iso8601Show dueAt)]

scheduleFiredEventId :: Text -> UTCTime -> EventId
scheduleFiredEventId agent dueAt =
  EventId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      fmap (fromIntegral . fromEnum) $
        Text.unpack $
          Text.intercalate ":" ["shikigami", "schedule-fired", agent, Text.pack (iso8601Show dueAt)]

armNextRun :: (Store :> es, IOE :> es) => CronSchedule -> Text -> UTCTime -> Eff es ()
armNextRun cron agent now =
  for_ (nextDue cron now) \dueAt ->
    runTransaction $
      scheduleTimerOnceTx
        TimerRequest
          { timerId = scheduleTimerId agent dueAt,
            processManagerName = "shikigami.scheduler",
            correlationId = agent,
            fireAt = dueAt,
            payload = scheduleTimerPayload agent dueAt
          }

scheduleFireAction :: (Store :> es, IOE :> es) => SchedulerEnv -> TimerRow -> Eff es (Maybe EventId)
scheduleFireAction env TimerRow {payload = timerPayload} =
  case parseSchedulePayload timerPayload of
    Nothing -> pure Nothing
    Just (agent, dueAt) -> do
      enqueued <- liftIO (enqueueScheduledRun (pool env) agent dueAt)
      case enqueued of
        Left _ -> pure Nothing
        Right _ -> do
          for_ (Map.lookup agent (schedules env)) \cron ->
            armNextRun cron agent dueAt
          pure (Just (scheduleFiredEventId agent dueAt))

shikigamiTimerFallback :: (Store :> es, IOE :> es) => SchedulerEnv -> TimerRow -> Eff es (Maybe EventId)
shikigamiTimerFallback env row =
  scheduleFireAction env row >>= \case
    Just eventId -> pure (Just eventId)
    Nothing -> Approval.approvalTimeoutFireAction row

runSchedulerTimerWorker ::
  (Store :> es, IOE :> es) =>
  AppEnv ->
  SchedulerEnv ->
  UTCTime ->
  Eff es (Maybe TimerRow)
runSchedulerTimerWorker appEnv env now =
  runWorkflowTimerWorker (metrics appEnv) now (shikigamiTimerFallback env)
