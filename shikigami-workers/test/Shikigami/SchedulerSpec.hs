module Shikigami.SchedulerSpec (tests) where

import Control.Exception (bracket, try)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Data.Vector qualified as Vector
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Keiro.Timer (TimerRow (..), TimerStatus (Firing), lookupTimer)
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Connection qualified as StoreConnection
import Pgmq (Message (..), MessageBody (..), ReadMessage (..), readMessage)
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Agent.RunJob (RunJob (..), TriggerKind (..))
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.Trigger.Enqueue (runQueueName)
import Shikigami.Trigger.Schedule (CatchUpPolicy (..), CronSchedule, nextDue, parseCron)
import Shikigami.Trigger.Scheduler (SchedulerEnv (..), armNextRun, parseSchedulePayload, runSchedulerTimerWorker, scheduleFireAction, scheduleTimerId, scheduleTimerPayload, shikigamiTimerFallback)
import Shikigami.Workers.Config (schedulerSchedules)
import System.Exit (ExitCode (ExitFailure))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Scheduler"
    [ testCase "nextDue returns the next minute for every-minute cron" do
        cron <- parseCronOrFail "* * * * *"
        let now = atSecond 30
            expected = atMinute 1
        assertEqual "next due minute" (Just expected) (nextDue cron now),
      testCase "payload round-trips" do
        let dueAt = atMinute 5
            payload = scheduleTimerPayload "heartbeat" dueAt
        assertEqual "recognized payload" (Just ("heartbeat", dueAt)) (parseSchedulePayload payload),
      testCase "timer id is deterministic" do
        let dueAt = atMinute 5
        assertEqual "same agent and due time produce same id" (scheduleTimerId "heartbeat" dueAt) (scheduleTimerId "heartbeat" dueAt),
      testCase "fire action enqueues a run job and re-arms" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            cron <- parseCronOrFail "* * * * *"
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                pool = StoreConnection.pool kirokuStore
                firstDue = atMinute 1
                env = testSchedulerEnv pool (Map.singleton "heartbeat" cron) FireAll Log.silentLogger

            armed <- runAppIO appEnv (armNextRun cron "heartbeat" (atSecond 30))
            assertEqual "initial arm succeeds" (Right ()) armed

            fired <- runAppIO appEnv (runSchedulerTimerWorker appEnv env firstDue)
            assertBool "due schedule timer fired" (either (const False) (maybe False (const True)) fired)

            messages <- readRunJobs pool
            case messages of
              [RunJob {agentName, triggerKind, occurredAt, idempotencyKey, triggerPayload}] -> do
                assertEqual "agent name" "heartbeat" agentName
                assertEqual "trigger kind" TriggeredBySchedule triggerKind
                assertEqual "occurred at due minute" firstDue occurredAt
                assertEqual "stable schedule idempotency key" "heartbeat:sched:2026-06-20T00:01:00Z" idempotencyKey
                assertEqual "payload parses as schedule" (Just ("heartbeat", firstDue)) (parseSchedulePayload triggerPayload)
              other -> assertFailure ("expected one run job, got " <> show other)

            refired <- runAppIO appEnv (runSchedulerTimerWorker appEnv env (atMinute 2))
            assertBool "re-armed next schedule timer fired" (either (const False) (maybe False (const True)) refired),
      -- The catch-up policy is a choice of what instant the next timer is armed
      -- from. Before it, a schedule fire always re-armed from the tick that just
      -- fired, so a process that had been down for a day walked forward one
      -- stale minute per pass: 1440 runs with 1440 distinct idempotency keys.
      testCase "waking a day late arms exactly one future run (SkipMissed)" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            cron <- parseCronOrFail "* * * * *"
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                pool = StoreConnection.pool kirokuStore
                env = testSchedulerEnv pool (Map.singleton "heartbeat" cron) SkipMissed Log.silentLogger

            fired <- runAppIO appEnv (scheduleFireAction env aDayLater (staleScheduleRow staleDue))
            assertEqual "the stale tick fired" (Right True) (fmap (maybe False (const True)) fired)

            messages <- readRunJobs pool
            assertEqual
              "waking a day late enqueues exactly the one run it was armed for"
              ["heartbeat:sched:2026-06-20T00:01:00Z"]
              [idempotencyKey job | job <- messages]

            staleNext <- expectedNext cron staleDue
            skippedNext <- expectedNext cron aDayLater
            stale <- runAppIO appEnv (lookupTimer (scheduleTimerId "heartbeat" staleNext))
            assertEqual "no timer is armed for the next stale minute" (Right Nothing) (fmap (fmap fireAt) stale)
            armed <- runAppIO appEnv (lookupTimer (scheduleTimerId "heartbeat" skippedNext))
            case armed of
              Right (Just TimerRow {fireAt}) ->
                assertBool
                  ("the re-armed tick is in the future: " <> show fireAt <> " vs " <> show aDayLater)
                  (fireAt > aDayLater)
              other -> assertFailure ("expected one timer armed after now, got " <> show (fmap (fmap fireAt) other)),
      testCase "FireAll still arms from the tick that fired" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            cron <- parseCronOrFail "* * * * *"
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                pool = StoreConnection.pool kirokuStore
                env = testSchedulerEnv pool (Map.singleton "heartbeat" cron) FireAll Log.silentLogger

            fired <- runAppIO appEnv (scheduleFireAction env aDayLater (staleScheduleRow staleDue))
            assertEqual "the stale tick fired" (Right True) (fmap (maybe False (const True)) fired)

            staleNext <- expectedNext cron staleDue
            armed <- runAppIO appEnv (lookupTimer (scheduleTimerId "heartbeat" staleNext))
            case armed of
              Right (Just TimerRow {fireAt}) ->
                assertBool
                  ("the re-armed tick is still in the past: " <> show fireAt <> " vs " <> show aDayLater)
                  (fireAt < aDayLater)
              other -> assertFailure ("expected the next stale minute to be armed, got " <> show (fmap (fmap fireAt) other)),
      -- Returning Nothing is how the fire action tells keiro "not fired, leave
      -- the row for requeue". Before this the Left was discarded, so at the
      -- composition point a failed enqueue and "this is not a schedule timer"
      -- were the same answer, and neither said anything.
      testCase "a failed schedule enqueue leaves the timer for requeue" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore ->
            withUnreachablePool connStr \brokenPool -> do
              tracer <- noopTracer
              cron <- parseCronOrFail "* * * * *"
              (logger, captured) <- capturingLogger
              let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                  env = testSchedulerEnv brokenPool (Map.singleton "heartbeat" cron) SkipMissed logger

              fired <- runAppIO appEnv (scheduleFireAction env aDayLater (staleScheduleRow staleDue))
              assertEqual "a failed enqueue does not report the timer as fired" (Right Nothing) (fmap (fmap (const ())) fired)

              lines' <- readIORef captured
              assertBool
                ("expected scheduler.schedule.enqueue_failed in " <> show lines')
                (any (ByteString.Char8.isInfixOf "\"event\":\"scheduler.schedule.enqueue_failed\"") lines')
              assertBool
                ("expected the agent name in " <> show lines')
                (any (ByteString.Char8.isInfixOf "\"agent\":\"heartbeat\"") lines')

              -- Nothing was enqueued anywhere, so the good pool's queue stays empty.
              skipped <- runAppIO appEnv (lookupTimer (scheduleTimerId "heartbeat" (atMinute 1441)))
              assertEqual "no next tick was armed after the failure" (Right Nothing) (fmap (fmap fireAt) skipped),
      -- Both payloads this runtime writes are kind-guarded, so the old
      -- try-then-fall-through never actually mis-fired an approval. What it did
      -- do was leave a row whose kind nobody claims indistinguishable from one
      -- the approval action declined, and say nothing about either.
      testCase "an unknown timer kind is reported, not silently approved" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            (logger, captured) <- capturingLogger
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                env = testSchedulerEnv (StoreConnection.pool kirokuStore) Map.empty SkipMissed logger
                row =
                  (staleScheduleRow staleDue)
                    { payload = Aeson.object ["kind" Aeson..= ("shikigami.not-a-timer-kind" :: Text)]
                    }

            fired <- runAppIO appEnv (shikigamiTimerFallback env aDayLater row)
            assertEqual "an unclaimed kind is not fired" (Right Nothing) (fmap (fmap (const ())) fired)

            lines' <- readIORef captured
            assertBool
              ("expected scheduler.timer.unknown_kind in " <> show lines')
              (any (ByteString.Char8.isInfixOf "\"event\":\"scheduler.timer.unknown_kind\"") lines'),
      -- The worker's schedule extraction was a pure mapMaybe, which is why it
      -- could only drop: an agent whose cron did not parse was removed from the
      -- timer loop's map, so it loaded fine, logged nothing, and never fired.
      testCase "an unparseable cron is reported, not dropped" do
        (logger, captured) <- capturingLogger
        schedules <- schedulerSchedules logger False [scheduledAgent "good-agent" "* * * * *", scheduledAgent "bad-agent" "not a cron"]
        assertEqual "only the parseable agent is scheduled" ["good-agent"] (Map.keys schedules)
        lines' <- readIORef captured
        assertBool
          ("expected scheduler.cron.invalid in " <> show lines')
          (any (ByteString.Char8.isInfixOf "\"event\":\"scheduler.cron.invalid\"") lines')
        assertBool
          ("the line names the offending agent: " <> show lines')
          (any (ByteString.Char8.isInfixOf "\"agent\":\"bad-agent\"") lines'),
      testCase "strict mode refuses to start on an unparseable cron" do
        (logger, captured) <- capturingLogger
        outcome <- try @ExitCode (schedulerSchedules logger True [scheduledAgent "bad-agent" "not a cron"])
        case outcome of
          Left code -> assertEqual "refusal exit code" (ExitFailure 1) code
          Right _ -> assertFailure "strict mode must refuse to start on an unparseable cron"
        lines' <- readIORef captured
        assertBool
          ("the offender is reported before the refusal: " <> show lines')
          (any (ByteString.Char8.isInfixOf "\"event\":\"scheduler.cron.invalid\"") lines'),
      testCase "a parseable cron under strict mode still starts" do
        (logger, _captured) <- capturingLogger
        schedules <- schedulerSchedules logger True [scheduledAgent "good-agent" "*/5 * * * *"]
        assertEqual "the agent is scheduled" ["good-agent"] (Map.keys schedules),
      testCase "an approval-timeout payload still reaches the approval action" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            (logger, captured) <- capturingLogger
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
                env = testSchedulerEnv (StoreConnection.pool kirokuStore) Map.empty SkipMissed logger
                row =
                  (staleScheduleRow staleDue)
                    { payload =
                        Aeson.object
                          [ "kind" Aeson..= Approval.approvalTimeoutKind,
                            "awakeableId" Aeson..= ("awk_absent" :: Text)
                          ]
                    }

            -- No such awakeable exists, so the approval action declines. What is
            -- being proved is which action was asked: the schedule dispatch did
            -- not claim the row, and it was not reported as an unknown kind.
            _ <- runAppIO appEnv (shikigamiTimerFallback env aDayLater row)
            lines' <- readIORef captured
            assertBool
              ("an approval payload must not be reported as unknown: " <> show lines')
              (not (any (ByteString.Char8.isInfixOf "scheduler.timer.unknown_kind") lines'))
    ]

-- | A minimal schedule-triggered declaration, for driving cron resolution.
scheduledAgent :: Text -> Text -> AgentDecl
scheduledAgent agentName cron =
  AgentDecl
    { name = agentName,
      description = "scheduler spec fixture",
      trigger = Schedule {cron},
      behavior = Deterministic {rule = "test", params = Map.empty},
      sinks = [],
      sanctionedProfile = Nothing,
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True
    }

-- | A 'SchedulerEnv' with the two fields every case below varies made explicit.
testSchedulerEnv :: Pool.Pool -> Map.Map Text CronSchedule -> CatchUpPolicy -> Log.Logger -> SchedulerEnv
testSchedulerEnv pool schedules catchUpPolicy logger =
  SchedulerEnv {pool, schedules, catchUpPolicy, logger}

-- | The minute the stale timer below was armed for: 2026-06-20T00:01:00Z.
staleDue :: UTCTime
staleDue = atMinute 1

-- | Twenty-four hours after 'staleDue', standing in for a process that was down
-- for a day and has just claimed the one timer it left behind.
aDayLater :: UTCTime
aDayLater = addUTCTime (24 * 60 * 60) staleDue

-- | The row keiro hands a fire action when it claims a due schedule timer.
staleScheduleRow :: UTCTime -> TimerRow
staleScheduleRow dueAt =
  TimerRow
    { timerId = scheduleTimerId "heartbeat" dueAt,
      processManagerName = "shikigami.scheduler",
      correlationId = "heartbeat",
      fireAt = dueAt,
      payload = scheduleTimerPayload "heartbeat" dueAt,
      status = Firing,
      attempts = 1,
      firedEventId = Nothing
    }

expectedNext :: CronSchedule -> UTCTime -> IO UTCTime
expectedNext cron from =
  maybe (assertFailure ("no next tick after " <> show from)) pure (nextDue cron from)

-- | A pool that cannot reach a database, for driving the enqueue-failure path.
--
-- libpq takes the last occurrence of a parameter, so appending a database name
-- that was never created turns the ephemeral server's own connection string into
-- one that cannot connect. This is a bare 'Pool.Pool' rather than a kioku store
-- because opening a store connects eagerly, and the point here is a pool whose
-- first use is its first failure — which is exactly what 'enqueueScheduledRun'
-- takes.
withUnreachablePool :: Text -> (Pool.Pool -> IO a) -> IO a
withUnreachablePool connStr =
  bracket
    ( Pool.acquire $
        Pool.Config.settings
          [ Pool.Config.staticConnectionSettings
              (fromString (Text.unpack (connStr <> " dbname=shikigami_no_such_database"))),
            Pool.Config.size 1,
            Pool.Config.acquisitionTimeout 5
          ]
    )
    Pool.release

-- | A logger that keeps every line it is given, so a case can assert on the
-- structured event rather than on a side effect the event happens to accompany.
capturingLogger :: IO (Log.Logger, IORef [ByteString])
capturingLogger = do
  captured <- newIORef []
  pure
    ( Log.Logger
        { Log.minLevel = Log.Debug,
          Log.sink = \line -> modifyIORef' captured (<> [line])
        },
      captured
    )

parseCronOrFail :: Text -> IO CronSchedule
parseCronOrFail expr =
  case parseCron expr of
    Right cron -> pure cron
    Left err -> assertFailure ("parse failed: " <> show err)

readRunJobs :: Pool.Pool -> IO [RunJob]
readRunJobs pool = do
  result <-
    Pool.use pool $
      readMessage
        ReadMessage
          { queueName = runQueueName,
            delay = 30,
            batchSize = Just 10,
            conditional = Nothing
          }
  case result of
    Left err -> assertFailure ("readMessage failed: " <> show err)
    Right messages ->
      pure
        [ job
        | Message {body = MessageBody payload} <- Vector.toList messages,
          Aeson.Success job <- [Aeson.fromJSON payload]
        ]

atMinute :: Integer -> UTCTime
atMinute minute =
  UTCTime (fromGregorian 2026 6 20) (secondsToDiffTime (minute * 60))

atSecond :: Integer -> UTCTime
atSecond second =
  UTCTime (fromGregorian 2026 6 20) (secondsToDiffTime second)
