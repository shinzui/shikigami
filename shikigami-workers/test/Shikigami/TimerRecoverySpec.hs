module Shikigami.TimerRecoverySpec (tests) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Hasql.Pool qualified as Pool
import Keiro.Timer
  ( DeadTimerClaimRequest (..),
    TimerId (..),
    TimerInspection (..),
    TimerRequest (..),
    TimerRow (..),
    TimerStatus (Dead),
    cancelTimer,
    claimDeadTimer,
    completeTimerResume,
    deadLetterTimer,
    lookupTimerInspection,
    markTimerFired,
    parkTimerResume,
    resumeClaimLeaseUntil,
    scheduleTimerTx,
  )
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Connection qualified as StoreConnection
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..))
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Trigger.Schedule (CatchUpPolicy (SkipMissed))
import Shikigami.Trigger.Scheduler (SchedulerEnv (..))
import Shikigami.Trigger.Timer (runTimerPass)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "Timer recovery"
    [ testCase "serving pass recovers an expired guarded claim and fences its stale token" do
        withShikigamiFreshDatabase fixture \connectionString ->
          withStore (defaultConnectionSettings connectionString) \store -> do
            tracer <- noopTracer
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connectionString, tracer, metrics = Nothing}
                scheduler = testSchedulerEnv (StoreConnection.pool store)
                request = guardedTimerRequest
                timerId = request.timerId
                reason = "deferred: authorized session required"
                claimRequest = DeadTimerClaimRequest timerId request.processManagerName reason 3 1
            scheduled <- runAppIO appEnv (runTransaction (scheduleTimerTx request))
            assertEqual "timer scheduled" (Right ()) scheduled
            parked <- runAppIO appEnv (deadLetterTimer timerId reason)
            assertEqual "timer parked" (Right True) parked
            claimed <- runAppIO appEnv (claimDeadTimer claimRequest)
            claim <- case claimed of
              Right (Right (Just value)) -> pure value
              _ -> assertFailure "guarded claim failed"

            runAppIO appEnv (cancelTimer timerId) >>= assertEqual "id cancellation cannot steal a claim" (Right False)
            runAppIO appEnv (deadLetterTimer timerId "replacement") >>= assertEqual "id dead-letter cannot steal a claim" (Right False)
            runAppIO appEnv (markTimerFired timerId resultEventId) >>= assertEqual "id completion cannot steal a claim" (Right False)

            awaitLeaseExpiry (resumeClaimLeaseUntil claim)
            now <- getCurrentTime
            runTimerPass appEnv Nothing scheduler now >>= assertEqual "recovery is maintenance, not dispatch" (Right 0)

            inspected <- runAppIO appEnv (lookupTimerInspection timerId)
            recovered <- case inspected of
              Right (Just value) -> pure value
              other -> assertFailure ("recovered timer missing: " <> show other)
            assertEqual "claim returns directly to Dead" Dead recovered.timer.status
            assertEqual "reason survives recovery" (Just reason) recovered.lastError
            assertEqual "payload survives recovery" request.payload recovered.timer.payload
            assertEqual "attempt survives recovery" 1 recovered.timer.attempts

            replacement <- runAppIO appEnv (claimDeadTimer (claimRequest {leaseSeconds = 60}))
            fresh <- case replacement of
              Right (Right (Just value)) -> pure value
              _ -> assertFailure "replacement claim failed"
            runAppIO appEnv (completeTimerResume claim resultEventId) >>= assertEqual "stale completion is fenced" (Right False)
            runAppIO appEnv (parkTimerResume fresh) >>= assertEqual "replacement owns the row" (Right True)
    ]

guardedTimerRequest :: TimerRequest
guardedTimerRequest =
  TimerRequest
    { timerId = TimerId (uuid "018f1000-0000-7000-8000-000000000001"),
      processManagerName = "shikigami.timer-recovery-test",
      correlationId = "timer-recovery",
      fireAt = read "2026-09-18 00:00:00 UTC",
      payload = object ["kind" .= ("guarded-recovery" :: Text)]
    }

resultEventId :: EventId
resultEventId = EventId (uuid "018f1000-0000-7000-8000-000000000002")

uuid :: String -> UUID.UUID
uuid value = maybe (error ("invalid test UUID: " <> value)) id (UUID.fromString value)

testSchedulerEnv :: Pool.Pool -> SchedulerEnv
testSchedulerEnv pool =
  SchedulerEnv
    { pool,
      schedules = Map.empty,
      principalIds = Map.empty,
      directory = disabledDirectoryHandle,
      catchUpPolicy = SkipMissed,
      logger = Log.silentLogger
    }

awaitLeaseExpiry :: UTCTime -> IO ()
awaitLeaseExpiry deadline = do
  started <- getCurrentTime
  let poll = do
        now <- getCurrentTime
        if now > deadline
          then pure ()
          else
            if realToFrac (now `diffUTCTime` started) > (3 :: Double)
              then assertBool "guarded timer lease expired within the bounded wait" False
              else threadDelay 10_000 >> poll
  poll
