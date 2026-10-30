-- | The worker probe answers the same contract the server does, and its
-- liveness check tells a wedged loop from an idle one.
--
-- Two kinds of test, because two different things can break.
--
-- The conformance group is @servant-health@'s own kit driving the /real/
-- assembled probe application over a real HTTP server on an ephemeral port. It
-- proves the routes exist at the exact paths, that a failing check answers 503
-- with the failed check named, and — the case that actually catches mistakes —
-- that the two same-typed routes were not wired to each other's checks.
--
-- The liveness group tests the check directly, because its interesting
-- properties are about elapsed time. They are reached by evaluating the check at
-- a chosen instant through 'loopLivenessAt' rather than by sleeping for a
-- staleness bound or by planting a fake heartbeat — either of which would leave
-- the staleness arithmetic itself untested.
module Shikigami.Health.WorkerSpec (tests) where

import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Network.Wai (Application)
import Servant.Health (ProbeCheck, ProbeVerdict (Healthy, Unhealthy))
import Servant.Health.TestKit (probeContractTests)
import Shibuya.Core.Metrics
  ( ProcessorMetrics (..),
    ProcessorState (Failed, Idle, Paused, Processing, Stopped),
    emptyInFlightInfo,
    emptyProcessorMetrics,
  )
import Shikigami.Health.Worker
  ( LoopName (ConsumerLoop, DirectoryLoop, OutboxLoop, QueueLoop, TimerLoop),
    beat,
    loopCheckName,
    loopLivenessAt,
    loopStaleAfter,
    newHeartbeats,
    newHeartbeatsWithStaleness,
    probeApplication,
    processorStateVerdict,
    registerReport,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "worker health"
    [ probeContractTests "worker probe contract" mkProbeApplication,
      livenessTests,
      supervisedTests
    ]

-- | The real probe application, with the checks supplied from outside.
--
-- The kit flips liveness and readiness independently, which is what proves the
-- routes are not transposed. A builder that ignored these and mounted the
-- process's real checks would prove nothing.
mkProbeApplication :: ProbeCheck -> ProbeCheck -> IO Application
mkProbeApplication livenessCheck readinessCheck =
  pure (probeApplication livenessCheck readinessCheck)

livenessTests :: TestTree
livenessTests =
  testGroup
    "loop liveness"
    [ -- An empty registry means "nothing claims to be watched", not "everything
      -- is dead". This is the state each worker role is in before its loops are
      -- registered, and it must pass.
      testCase "a registry with no loops is healthy" do
        registry <- newHeartbeats []
        now <- getCurrentTime
        loopLivenessAt registry now >>= assertHealthy,
      testCase "a loop that just beat is healthy" do
        registry <- newHeartbeats [OutboxLoop, TimerLoop]
        beat registry OutboxLoop
        now <- getCurrentTime
        loopLivenessAt registry now >>= assertHealthy,
      -- The property a boolean flag could not express: a loop with no work to do
      -- is not a loop in trouble, so an idle-but-beating process stays 200 rather
      -- than being restarted for being quiet.
      testCase "a loop still inside its bound is healthy" do
        registry <- newHeartbeats [OutboxLoop]
        born <- getCurrentTime
        loopLivenessAt registry (addUTCTime (loopStaleAfter OutboxLoop - 1) born)
          >>= assertHealthy,
      testCase "a loop past its bound fails, naming itself" do
        registry <- newHeartbeats [OutboxLoop]
        born <- getCurrentTime
        verdict <- loopLivenessAt registry (addUTCTime (loopStaleAfter OutboxLoop + 5) born)
        failedCheckOf verdict >>= (@?= loopCheckName OutboxLoop),
      -- failingSince must be when the loop went stale, not when the probe looked.
      -- Otherwise a dashboard reports a fresh incident on every scrape and an
      -- operator cannot tell a minute of trouble from an hour of it.
      testCase "failingSince is the threshold crossing, not the observation" do
        registry <- newHeartbeats [OutboxLoop]
        born <- getCurrentTime
        let observedAt = addUTCTime (loopStaleAfter OutboxLoop + 300) born
        verdict <- loopLivenessAt registry observedAt
        onset <- onsetOf verdict
        -- The crossing is one bound after the last beat, which for a registry
        -- that has never beaten is one bound after it was created.
        assertBool
          ("onset " <> show onset <> " should be well before the observation " <> show observedAt)
          (onset < observedAt)
        assertBool
          ("onset " <> show onset <> " should be about one bound after creation")
          (abs (diffUTCTime onset (addUTCTime (loopStaleAfter OutboxLoop) born)) < 1),
      -- Two sick loops must not make the probe alternate between two names, or a
      -- runbook keyed on the check name fires against a moving target.
      testCase "the first stale loop in constructor order wins" do
        registry <- newHeartbeats [OutboxLoop, ConsumerLoop]
        born <- getCurrentTime
        -- Past both bounds, so both loops are stale and only the order decides.
        verdict <- loopLivenessAt registry (addUTCTime (loopStaleAfter ConsumerLoop + 5) born)
        failedCheckOf verdict >>= (@?= loopCheckName OutboxLoop),
      -- Each loop is judged against its own cadence rather than one global
      -- number: at the same instant the ten-second loop is stale, the
      -- sixty-second one is still fine.
      testCase "each loop is judged against its own bound" do
        outboxOnly <- newHeartbeats [OutboxLoop]
        consumerOnly <- newHeartbeats [ConsumerLoop]
        born <- getCurrentTime
        let observedAt = addUTCTime (loopStaleAfter OutboxLoop + 5) born
        outboxVerdict <- loopLivenessAt outboxOnly observedAt
        failedCheckOf outboxVerdict >>= (@?= loopCheckName OutboxLoop)
        loopLivenessAt consumerOnly observedAt >>= assertHealthy,
      testCase "directory liveness follows its configured refresh cadence" do
        registry <- newHeartbeatsWithStaleness [(DirectoryLoop, 300)]
        born <- getCurrentTime
        loopLivenessAt registry (addUTCTime 299 born) >>= assertHealthy
        verdict <- loopLivenessAt registry (addUTCTime 301 born)
        failedCheckOf verdict >>= (@?= "loop.directory"),
      -- An unregistered loop belongs to a different role. The scheduler runs no
      -- outbox publisher and must not fail liveness for not having one.
      testCase "a loop this role does not run is not checked" do
        -- The registered loop's own bound is not reached at the observation
        -- instant, so anything unhealthy here could only come from the
        -- unregistered outbox loop, whose bound is long past.
        registry <- newHeartbeats [ConsumerLoop]
        born <- getCurrentTime
        loopLivenessAt registry (addUTCTime (loopStaleAfter OutboxLoop + 5) born)
          >>= assertHealthy,
      -- The queue processor reports through shibuya rather than beating, so its
      -- verdict comes from the registered reporter and no heartbeat is involved.
      testCase "a registered reporter decides its loop's verdict" do
        registry <- newHeartbeats []
        onset <- getCurrentTime
        registerReport registry QueueLoop (pure (Unhealthy (loopCheckName QueueLoop) onset))
        verdict <- loopLivenessAt registry onset
        failedCheckOf verdict >>= (@?= loopCheckName QueueLoop)
        onsetOf verdict >>= (@?= onset),
      testCase "a healthy reporter does not mask a stale sibling" do
        registry <- newHeartbeats [OutboxLoop]
        born <- getCurrentTime
        registerReport registry QueueLoop (pure Healthy)
        verdict <- loopLivenessAt registry (addUTCTime (loopStaleAfter OutboxLoop + 5) born)
        failedCheckOf verdict >>= (@?= loopCheckName OutboxLoop),
      -- Registering twice must replace rather than accumulate, so a supervisor
      -- that restarts does not leave the probe reading a dead reporter.
      testCase "re-registering a reporter replaces the previous one" do
        registry <- newHeartbeats []
        now <- getCurrentTime
        registerReport registry QueueLoop (pure (Unhealthy "stale-reporter" now))
        registerReport registry QueueLoop (pure Healthy)
        loopLivenessAt registry now >>= assertHealthy
    ]

-- | The shibuya-supervised loops — the run-job queue processor and each Kafka
-- consumer — report through the supervisor's own state rather than a heartbeat.
-- These are the cases that make that worth doing.
supervisedTests :: TestTree
supervisedTests =
  testGroup
    "supervised loop verdicts"
    [ -- The case a heartbeat gets wrong. A processor waiting on a quiet topic
      -- has nothing to beat about, so a heartbeat-only consumer would go stale
      -- and be restarted for having no work.
      testCase "an idle processor is healthy" do
        now <- getCurrentTime
        processorStateVerdict ConsumerLoop now (Just (metricsIn Idle now)) @?= Healthy,
      testCase "a processor working within its bound is healthy" do
        now <- getCurrentTime
        let lastActivity = addUTCTime (negate (loopStaleAfter ConsumerLoop - 5)) now
        processorStateVerdict ConsumerLoop now (Just (metricsIn (Processing (emptyInFlightInfo 1) lastActivity lastActivity) now))
          @?= Healthy,
      -- The case a bare state check gets wrong. "Processing" is not by itself
      -- good news: a record in flight for ten minutes is a wedge.
      testCase "a processor stuck past its bound is unhealthy" do
        now <- getCurrentTime
        let lastActivity = addUTCTime (negate (loopStaleAfter ConsumerLoop + 5)) now
            verdict = processorStateVerdict ConsumerLoop now (Just (metricsIn (Processing (emptyInFlightInfo 1) lastActivity lastActivity) now))
        failedCheckOf verdict >>= (@?= loopCheckName ConsumerLoop)
        onsetOf verdict >>= (@?= addUTCTime (loopStaleAfter ConsumerLoop) lastActivity),
      -- What no heartbeat could report at all: the failure's own timestamp,
      -- rather than whenever the probe next looked.
      testCase "a failed processor is dated by its own failure, not the probe" do
        now <- getCurrentTime
        let failedAt = addUTCTime (negate 3600) now
            verdict = processorStateVerdict QueueLoop now (Just (metricsIn (Failed "boom" failedAt) now))
        failedCheckOf verdict >>= (@?= loopCheckName QueueLoop)
        onsetOf verdict >>= (@?= failedAt),
      -- Under IgnoreFailures a stopped processor is a silent death, which is the
      -- hole this whole plan exists to close.
      testCase "a paused processor uses last progress for its health bound" do
        now <- getCurrentTime
        let recent = addUTCTime (-5) now
            stale = addUTCTime (negate (loopStaleAfter ConsumerLoop + 5)) now
        processorStateVerdict ConsumerLoop now (Just (metricsIn (Paused (emptyInFlightInfo 1) stale recent) now)) @?= Healthy
        let verdict = processorStateVerdict ConsumerLoop now (Just (metricsIn (Paused (emptyInFlightInfo 1) recent stale) now))
        failedCheckOf verdict >>= (@?= loopCheckName ConsumerLoop)
        onsetOf verdict >>= (@?= addUTCTime (loopStaleAfter ConsumerLoop) stale),
      testCase "a stopped processor is unhealthy" do
        now <- getCurrentTime
        verdict <- pure (processorStateVerdict QueueLoop now (Just (metricsIn Stopped now)))
        failedCheckOf verdict >>= (@?= loopCheckName QueueLoop),
      -- A processor id the supervisor never registered means nothing is draining
      -- the queue, which must not read as "no news is good news".
      testCase "an unregistered processor is unhealthy" do
        now <- getCurrentTime
        verdict <- pure (processorStateVerdict QueueLoop now Nothing)
        failedCheckOf verdict >>= (@?= loopCheckName QueueLoop)
    ]

-- ── Helpers ─────────────────────────────────────────────────────────────────

-- | Metrics carrying a chosen state; the counters are irrelevant to the verdict.
metricsIn :: ProcessorState -> UTCTime -> ProcessorMetrics
metricsIn processorState startedAt =
  (emptyProcessorMetrics startedAt) {state = processorState}

assertHealthy :: ProbeVerdict -> IO ()
assertHealthy verdict =
  assertBool ("expected Healthy, got " <> show verdict) (verdict == Healthy)

failedCheckOf :: ProbeVerdict -> IO Text
failedCheckOf = \case
  Unhealthy name _ -> pure name
  Healthy -> assertFailure "expected an Unhealthy verdict, got Healthy"

onsetOf :: ProbeVerdict -> IO UTCTime
onsetOf = \case
  Unhealthy _ onset -> pure onset
  Healthy -> assertFailure "expected an Unhealthy verdict, got Healthy"
