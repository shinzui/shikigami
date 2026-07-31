module Shikigami.SchedulerSpec (tests) where

import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.Vector qualified as Vector
import Hasql.Pool qualified as Pool
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Connection qualified as StoreConnection
import Pgmq (Message (..), MessageBody (..), ReadMessage (..), readMessage)
import Shikigami.Agent.RunJob (RunJob (..), TriggerKind (..))
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.Trigger.Enqueue (runQueueName)
import Shikigami.Trigger.Schedule (CronSchedule, nextDue, parseCron)
import Shikigami.Trigger.Scheduler (SchedulerEnv (..), armNextRun, parseSchedulePayload, runSchedulerTimerWorker, scheduleTimerId, scheduleTimerPayload)
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
            let appEnv = AppEnv {store = kirokuStore, tracer, metrics = Nothing}
                pool = StoreConnection.pool kirokuStore
                firstDue = atMinute 1
                env = SchedulerEnv {pool, schedules = Map.singleton "heartbeat" cron}

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
            assertBool "re-armed next schedule timer fired" (either (const False) (maybe False (const True)) refired)
    ]

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
