{-# LANGUAGE DataKinds #-}

module Shikigami.Trigger.Scheduler
  ( SchedulerEnv (..),
    scheduleTimerKind,
    scheduleTimerPayload,
    parseSchedulePayload,
    timerPayloadKind,
    scheduleTimerId,
    armNextRun,
    scheduleFireAction,
    shikigamiTimerFallback,
    runSchedulerTimerWorker,
  )
where

import Data.Aeson (Value, (.:), (.=))
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
import Keiro.Workflow.Sleep (drainWorkflowSleepTimers)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..))
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Principal (AgentIdentity (..), compatibilityIdentity, mkAgentPrincipal)
import Shikigami.Agent.RunJob (RunJob (..))
import Shikigami.App (AppEnv (..))
import Shikigami.Coordination.Wake qualified as AdaptiveWake
import Shikigami.Directory qualified as Directory
import Shikigami.Directory.Store (RunSkip (..), SkipStage (TriggerStage), recordRunSkip, reportedPrincipalClaim)
import Shikigami.Execution.Identity (newExecutionRootId)
import Shikigami.Execution.Timer qualified as ExecutionTimer
import Shikigami.Log qualified as Log
import Shikigami.Mandate.Timer qualified as MandateTimer
import Shikigami.Mandate.Wake qualified as MandateWake
import Shikigami.Prelude hiding ((.=))
import Shikigami.Trigger.Enqueue (enqueueRunJobTx, enqueueScheduledRun, scheduleRunIdempotencyKey, scheduledRunJob)
import Shikigami.Trigger.Schedule (CatchUpPolicy (..), CronSchedule, nextDue)
import Shikigami.Watchdog.Admission
import Shikigami.Watchdog.Settings (WatchdogSettings)

data SchedulerEnv = SchedulerEnv
  { pool :: !Pool,
    schedules :: !(Map AgentName CronSchedule),
    declarations :: ![AgentDecl],
    watchdog :: !(Maybe WatchdogSettings),
    -- | Declaration principal ids keyed by scheduled agent name.
    principalIds :: !(Map AgentName (Maybe (DeclarationCoordinate "principal"))),
    directory :: !Directory.DirectoryHandle,
    -- | What to do about cron minutes that passed while the process was down.
    catchUpPolicy :: !CatchUpPolicy,
    -- | Where the timer loop reports what it did and what it could not do.
    logger :: !Log.Logger
  }

data ScheduleTimerPayload = ScheduleTimerPayload
  { kind :: !Text,
    agent :: !AgentName,
    dueAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

scheduleTimerKind :: Text
scheduleTimerKind = "shikigami.schedule"

scheduleTimerPayload :: AgentName -> UTCTime -> Value
scheduleTimerPayload agent dueAt =
  Aeson.toJSON ScheduleTimerPayload {kind = scheduleTimerKind, agent, dueAt}

parseSchedulePayload :: Value -> Maybe (AgentName, UTCTime)
parseSchedulePayload value = do
  ScheduleTimerPayload {kind, agent, dueAt} <- parseMaybe Aeson.parseJSON value
  if kind == scheduleTimerKind
    then Just (agent, dueAt)
    else Nothing

-- | Every timer payload this runtime writes self-describes through a @kind@
-- field. Reading it is what lets the dispatch below say which action owns a row
-- instead of discovering it by trying one action and seeing whether it declined.
timerPayloadKind :: Value -> Maybe Text
timerPayloadKind = parseMaybe (Aeson.withObject "timer payload" (.: "kind"))

scheduleTimerId :: AgentName -> UTCTime -> TimerId
scheduleTimerId agent dueAt =
  TimerId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      nameBytes $
        Text.intercalate ":" ["shikigami", "schedule", agentNameText agent, Text.pack (iso8601Show dueAt)]

scheduleFiredEventId :: AgentName -> UTCTime -> EventId
scheduleFiredEventId agent dueAt =
  EventId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      nameBytes $
        Text.intercalate ":" ["shikigami", "schedule-fired", agentNameText agent, Text.pack (iso8601Show dueAt)]

armNextRun :: (Store :> es, IOE :> es) => CronSchedule -> AgentName -> UTCTime -> Eff es ()
armNextRun cron agent now =
  for_ (nextDue cron now) \dueAt ->
    runTransaction $
      scheduleTimerOnceTx
        TimerRequest
          { timerId = scheduleTimerId agent dueAt,
            processManagerName = "shikigami.scheduler",
            correlationId = agentNameText agent,
            fireAt = dueAt,
            payload = scheduleTimerPayload agent dueAt
          }

-- | Enqueue the run this timer was armed for, then arm the next one.
--
-- @now@ is the instant keiro used to decide this timer was due, threaded through
-- rather than read again, so the re-arm cannot disagree with the claim.
--
-- Under 'SkipMissed' the next timer is armed from @now@, so a process that wakes
-- a day late arms one future tick rather than the next stale minute; 'nextDue'
-- already returns the first strictly-future match, so no loop is needed. Under
-- 'FireAll' the next timer is armed from the tick that just fired, which
-- reproduces the pre-policy backlog drain.
scheduleFireAction :: (Store :> es, IOE :> es) => SchedulerEnv -> UTCTime -> TimerRow -> Eff es (Maybe EventId)
scheduleFireAction env now TimerRow {payload = timerPayload} =
  case parseSchedulePayload timerPayload of
    Nothing -> pure Nothing
    Just (agent, dueAt) -> do
      let declaredPrincipalId = Map.findWithDefault Nothing agent ((.principalIds) env)
      decision <- liftIO (Directory.consultLifecycle ((.directory) env) declaredPrincipalId (agentNameText agent))
      let advance = do
            let armFrom = case (.catchUpPolicy) env of
                  SkipMissed -> now
                  FireAll -> dueAt
            for_ (Map.lookup agent ((.schedules) env)) \cron ->
              armNextRun cron agent armFrom
            pure (Just (scheduleFiredEventId agent dueAt))
      let admission = do
            identity <- admittedIdentity agent declaredPrincipalId decision
            allowance <- case [declaration | declaration <- env.declarations, declaration.name == agent] of
              [declaration] -> either (Left . (declaredPrincipalId,)) Right (watchdogAllowance env.watchdog declaration identity)
              _ -> Right Nothing
            pure (identity, allowance)
      case admission of
        Right (identity, allowance) -> do
          enqueued <- case allowance of
            Nothing -> fmap (either (Left . Text.pack . show) (const (Right ()))) (liftIO (enqueueScheduledRun ((.pool) env) identity agent dueAt))
            Just policy -> do
              candidate <- liftIO newExecutionRootId
              enrolled <- runTransaction do
                enrollScheduledWatchdogTx candidate policy now (scheduledRunJob identity agent dueAt) >>= \case
                  Left problem -> pure (Left problem)
                  Right job -> Right <$> enqueueRunJobTx job
              pure (fmap (const ()) enrolled)
          case enqueued of
            -- Returning Nothing leaves the row in Firing for keiro to requeue. The
            -- log line is what makes that retry visible: before it, a failed enqueue
            -- was indistinguishable from "this is not a schedule timer".
            Left err -> do
              liftIO $
                Log.logError
                  ((.logger) env)
                  "scheduler.schedule.enqueue_failed"
                  [ "agent" .= agent,
                    "due_at" .= dueAt,
                    "error" .= Text.pack (show err)
                  ]
              pure Nothing
            Right _ -> advance
        Left (resolvedPrincipalId, reason) -> do
          let runSkip =
                RunSkip
                  { agentName = agent,
                    principalId = (reportedPrincipalClaim . declarationCoordinateText) <$> resolvedPrincipalId,
                    stage = TriggerStage,
                    detail = "schedule",
                    reason,
                    idempotencyKey = scheduleRunIdempotencyKey agent dueAt
                  }
          liftIO (recordRunSkip ((.pool) env) runSkip) >>= \case
            Left problem -> do
              liftIO $
                Log.logError
                  ((.logger) env)
                  "scheduler.schedule.skip_failed"
                  [ "agent" .= agent,
                    "due_at" .= dueAt,
                    "reason" .= reason,
                    "error" .= problem
                  ]
              pure Nothing
            Right () -> do
              liftIO $
                Log.logInfo
                  ((.logger) env)
                  "scheduler.schedule.skipped"
                  [ "agent" .= agent,
                    "due_at" .= dueAt,
                    "principal_id" .= resolvedPrincipalId,
                    "reason" .= reason
                  ]
              advance

admittedIdentity :: AgentName -> Maybe (DeclarationCoordinate "principal") -> Directory.LifecycleDecision -> Either (Maybe (DeclarationCoordinate "principal"), Text) AgentIdentity
admittedIdentity agent declaredPrincipalId = \case
  Directory.AllowRun Nothing -> Right (compatibilityIdentity agent)
  Directory.AllowRun (Just principal) ->
    case mkAgentPrincipal (declarationCoordinateText ((.principalId) principal)) of
      Left reason -> Left (Just ((.principalId) principal), reason)
      Right admittedPrincipal -> Right (VerifiedIdentity admittedPrincipal)
  Directory.SkipRun principal reason -> Left (Just ((.principalId) principal), reason)
  Directory.UnknownPrincipal identifier -> Left (declaredPrincipalId, "unknown principal: " <> identifier)
  Directory.DirectoryUnavailable problem -> Left (declaredPrincipalId, "directory unavailable: " <> problem)

-- | Route one due timer row to the action that owns its kind.
--
-- Every payload this runtime writes carries a @kind@ discriminator, so the
-- dispatch reads it rather than trying each action and falling through on
-- 'Nothing'. The observable behavior for a well-formed timer is unchanged; what
-- changes is that the code says which action owns which row, and that a row
-- carrying a kind nobody claims is reported instead of silently left to expire.
--
-- Three kinds now: a scheduled agent whose cron came round, an approval that
-- waited too long, and a conversation that has been idle too long. All three go
-- through this one loop rather than gaining loops of their own, because a timer
-- table with two independent readers races -- see "Shikigami.Trigger.Timer".
shikigamiTimerFallback :: (Store :> es, IOE :> es) => SchedulerEnv -> UTCTime -> TimerRow -> Eff es (Maybe EventId)
shikigamiTimerFallback env now row@TimerRow {payload = timerPayload, timerId = TimerId rowTimerId} =
  case timerPayloadKind timerPayload of
    Just kind
      | kind == scheduleTimerKind -> scheduleFireAction env now row
      | kind == MandateWake.timerKind -> MandateTimer.fireAction row
      | kind == AdaptiveWake.cutoffTimerKind -> AdaptiveWake.cutoffFireAction row
      | kind == ExecutionTimer.observationTimerKind -> ExecutionTimer.observationFireAction row
      | kind == Approval.approvalTimeoutKind -> Approval.approvalTimeoutFireAction row
      | kind == Conversation.conversationIdleTimeoutKind -> Conversation.conversationIdleTimeoutFireAction row
    other -> do
      liftIO $
        Log.logError
          ((.logger) env)
          "scheduler.timer.unknown_kind"
          [ "timer_id" .= show rowTimerId,
            "timer_kind" .= other
          ]
      pure Nothing

runSchedulerTimerWorker ::
  (Store :> es, IOE :> es) =>
  AppEnv ->
  SchedulerEnv ->
  UTCTime ->
  Eff es Int
runSchedulerTimerWorker appEnv env now =
  drainWorkflowSleepTimers (appEnv.metrics) now 100 (shikigamiTimerFallback env now)
