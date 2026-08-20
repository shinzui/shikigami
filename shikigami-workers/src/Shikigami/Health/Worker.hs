-- | Probes for the worker-role processes: what \"alive\" means for a background
-- loop, and the listener that answers.
--
-- @shikigami-server@ answers @GET \/health\/live@ and @GET \/health\/ready@ on
-- the socket it already serves the API from. The four worker executables serve
-- no API, so each opens a small listener of its own on @health.port@ and answers
-- the /same two routes with the same bodies/. Operators, dashboards, and
-- @process-compose@ probes should not have to know which kind of process they
-- are looking at.
--
-- Sameness is structural rather than a convention: both families mount
-- @servant-health@'s @HealthApi@ and both are proved by the same
-- @servant-health:testkit@ conformance suite. @servant-health@ is an /external/
-- package, so depending on it here introduces no dependency on a Shikigami
-- sibling — @shikigami-workers@ may not see @shikigami-api@ or
-- @shikigami-server@, and "Shikigami.PackageArchitectureSpec" fails the build if
-- it ever does.
--
-- == Why liveness is a timestamp and not a flag
--
-- A boolean \"the loop is running\" cannot tell a healthy idle loop from one
-- wedged forever inside a single iteration — both are \"running\". A timestamp
-- can: each loop records when it last completed a pass, and a pass that has not
-- happened for longer than that loop's cadence allows is a wedge. This is also
-- why answering the HTTP request is /not/ the liveness check here, the way it is
-- on the server: the probe listener is its own thread, and it would happily
-- answer 200 next to four dead loops.
--
-- == The three hardening decisions
--
-- Reproduced from "Shikigami.Health.Handler" deliberately, because getting any
-- of them wrong fails silently and the temptation to skip them because \"it is
-- only a worker\" is exactly how a wedged process ends up passing its own
-- liveness probe.
--
--   * Every check is wrapped in @safeCheck@, so an exception escaping a check
--     becomes a probe report naming the failed dependency rather than a 500 with
--     a stack trace.
--   * @withProbeTimeout@ sits /outside/ @safeCheck@ on liveness. The timeout
--     interrupts by throwing an asynchronous exception and @safeCheck@
--     deliberately lets those through; nested the other way round a deadlocked
--     process would hang its liveness probe instead of failing it.
--   * Each probe gets its own failure tracker, so @failingSince@ reports when a
--     failure began rather than when it was last observed. The trackers hold
--     state, which is why the checks are built once at boot rather than per
--     request.
module Shikigami.Health.Worker
  ( -- * The loops a process can run
    LoopName (..),
    loopCheckName,
    loopStaleAfter,

    -- * Heartbeats
    Heartbeats,
    newHeartbeats,
    beat,
    registerReport,
    clearReport,

    -- * Checks
    loopLivenessCheck,
    loopLivenessAt,
    supervisedLoopVerdict,
    processorStateVerdict,
    postgresReadiness,
    mkWorkerHealthChecks,

    -- * Serving
    WorkerProbeApi (..),
    probeApplication,
    runProbeListener,
    serveProbesWith,

    -- * Loop death
    LoopExited (..),
  )
where

import Control.Concurrent.Async (concurrently_)
import Control.Exception (Exception)
import Data.Aeson qualified as Aeson
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, addUTCTime)
import Hasql.Pool (Pool)
import Network.Wai (Application)
import Network.Wai.Handler.Warp qualified as Warp
import Servant.API (NamedRoutes, (:>))
import Servant.API.Generic ((:-))
import Servant.Health (HealthApi, ProbeCheck, ProbeVerdict (Healthy, Unhealthy), healthServer)
import Servant.Health.Check (boolCheck, newFailureTracker, safeCheck, sequenceChecks, withProbeTimeout)
import Servant.Server.Generic (genericServe)
import Shibuya.App (Master, ProcessorId, ProcessorMetrics (..), getProcessorMetricsIO)
import Shibuya.Core.Metrics (ProcessorState (Failed, Idle, Processing, Stopped))
import Shikigami.App.Config (Port, portNumber)
import Shikigami.Health.Ping (databaseReachable, postgresCheckName)
import Shikigami.Log qualified as Log
import Shikigami.Prelude

-- ── The loops ───────────────────────────────────────────────────────────────

-- | Every long-running loop any worker-role process runs.
--
-- One type across all four executables rather than one per binary, so a check
-- name means the same thing in every process's 503 body. A given process
-- registers only the loops it actually runs; an unregistered loop is not
-- checked, which is what keeps the scheduler from failing liveness for having no
-- outbox publisher.
--
-- The 'Ord' instance is load-bearing: 'loopLivenessCheck' reports the first
-- failing loop in constructor order, so a process with two wedged loops reports
-- the same one on every probe rather than alternating between them.
data LoopName
  = QueueLoop
  | ResumeLoop
  | OutboxLoop
  | TimerLoop
  | ConsumerLoop
  | SchedulerLoop
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The name a failed loop reports under, and therefore the string an operator
-- reads in the 503 body and matches on in a runbook.
loopCheckName :: LoopName -> Text
loopCheckName = \case
  QueueLoop -> "loop.queue"
  ResumeLoop -> "loop.resume"
  OutboxLoop -> "loop.outbox"
  TimerLoop -> "loop.timer"
  ConsumerLoop -> "loop.consumer"
  SchedulerLoop -> "loop.scheduler"

-- | How long a loop may go without a heartbeat before it is considered wedged.
--
-- Set from each loop's own cadence, not from one global number. The outbox,
-- timer, resume, and scheduler loops finish a pass and sleep one second, so ten
-- seconds is roughly ten missed passes — long enough to absorb a GC pause or a
-- slow query, short enough that a wedge is caught within a couple of probe
-- periods.
--
-- The consumers get a minute because their pass is a blocking poll against
-- Kafka whose duration is the broker's to decide, not ours. They beat on each
-- poll /attempt/ rather than only on a matched record, so an idle topic still
-- looks alive; the longer bound covers the poll interval itself.
--
-- 'QueueLoop' has no bound because it never beats: shibuya already tracks the
-- processor's own liveness and 'registerReport' reads that instead. Its value
-- here is unused and exists only to keep the function total.
loopStaleAfter :: LoopName -> NominalDiffTime
loopStaleAfter = \case
  QueueLoop -> 60
  ResumeLoop -> 10
  OutboxLoop -> 10
  TimerLoop -> 10
  ConsumerLoop -> 60
  SchedulerLoop -> 10

-- ── Heartbeats ──────────────────────────────────────────────────────────────

-- | What each of this process's loops last said about itself.
--
-- Two kinds of loop, because two kinds of truth are available. Most loops are
-- plain @forever@ bodies that nothing else observes, so they say \"I finished a
-- pass\" by writing the clock into 'beats'. The run-job queue processor runs
-- under shibuya's supervisor, which already records what the processor actually
-- did — including a @Failed@ state carrying the error and when it happened —
-- so it registers a 'reports' entry that reads that instead. A snapshot of what
-- a loop did beats a callback recording when we last remembered to call it.
data Heartbeats = Heartbeats
  { beats :: !(Map LoopName (IORef UTCTime)),
    -- | Filled after the process starts, because a supervised loop's reporter
    -- does not exist until its supervisor is running.
    reports :: !(IORef (Map LoopName (IO ProbeVerdict)))
  }

-- | Create a registry for exactly the loops this process runs.
--
-- Every registered loop starts beating now rather than at the epoch, so a
-- process is not born failing its own liveness probe during the seconds between
-- the listener binding and the first pass completing.
newHeartbeats :: [LoopName] -> IO Heartbeats
newHeartbeats loops = do
  now <- getCurrentTime
  cells <- traverse (\loop -> (loop,) <$> newIORef now) loops
  reported <- newIORef Map.empty
  pure Heartbeats {beats = Map.fromList cells, reports = reported}

-- | Record that a loop just completed a pass.
--
-- Call it at the bottom of the loop body, before the sleep. A loop that is not
-- registered is silently ignored, which is what lets one loop's module call
-- 'beat' without knowing which role it was composed into.
beat :: Heartbeats -> LoopName -> IO ()
beat Heartbeats {beats} loop =
  case Map.lookup loop beats of
    Nothing -> pure ()
    Just cell -> getCurrentTime >>= atomicWriteIORef cell

-- | Hand a loop's liveness over to something that already tracks it.
--
-- The action must not block: it is run inside a probe request. Registering
-- replaces any previous reporter for that loop, so a supervisor that restarts
-- can re-register without the registry accumulating stale readers.
registerReport :: Heartbeats -> LoopName -> IO ProbeVerdict -> IO ()
registerReport Heartbeats {reports} loop report =
  readIORef reports >>= atomicWriteIORef reports . Map.insert loop report

-- | Hand a loop's liveness back to its heartbeat.
--
-- The counterpart to 'registerReport', for a loop whose reporter has gone away —
-- a consumer between connections, whose supervisor died with the connection.
-- Beat before clearing: the loop's heartbeat has not moved while the reporter
-- was answering for it, so clearing first would strand a heartbeat as old as the
-- registration and fail liveness on a loop that is demonstrably still going
-- round.
clearReport :: Heartbeats -> LoopName -> IO ()
clearReport Heartbeats {reports} loop =
  readIORef reports >>= atomicWriteIORef reports . Map.delete loop

-- ── Checks ──────────────────────────────────────────────────────────────────

-- | Is every loop in this process still making progress?
--
-- Performs no network or database IO: it reads in-memory cells only, so a probe
-- cannot be slowed or failed by the very dependency outage that readiness exists
-- to report.
--
-- Loops are examined in 'LoopName' order and the first failure wins, so a
-- process with two sick loops names the same one on every probe. A stale loop's
-- @failingSince@ is the instant its last heartbeat /crossed/ the threshold — not
-- the moment of observation — so the reported onset does not depend on when
-- Kubernetes happened to ask.
loopLivenessCheck :: Heartbeats -> ProbeCheck
loopLivenessCheck registry = getCurrentTime >>= loopLivenessAt registry

-- | 'loopLivenessCheck' with the clock supplied.
--
-- The verdict is a function of the registry and the current instant, and this is
-- that function. Exposed because otherwise the only way to test what happens
-- after a staleness bound elapses is to sleep for it, which makes the suite slow
-- and — worse — makes the tempting alternative a fake heartbeat that exercises
-- none of the arithmetic below.
loopLivenessAt :: Heartbeats -> UTCTime -> IO ProbeVerdict
loopLivenessAt registry@Heartbeats {beats} now = do
  reported <- readIORef (reports registry)
  go reported [minBound .. maxBound]
  where
    go _ [] = pure Healthy
    go reported (loop : rest) =
      case Map.lookup loop reported of
        Just report ->
          report >>= \case
            Healthy -> go reported rest
            failure -> pure failure
        Nothing ->
          case Map.lookup loop beats of
            Nothing -> go reported rest
            Just cell -> do
              lastBeat <- readIORef cell
              let deadline = addUTCTime (loopStaleAfter loop) lastBeat
              if now > deadline
                then pure (Unhealthy (loopCheckName loop) deadline)
                else go reported rest

-- | Translate a shibuya-supervised processor's own state into a probe verdict.
--
-- Two of this repository's loops — the run-job queue processor and each Kafka
-- consumer — run under shibuya's supervisor, which already records what the
-- processor actually did. Reading that is strictly more truthful than a
-- heartbeat, which records when Shikigami last remembered to call a function,
-- and it reports a @Failed@ state carrying the error and its timestamp that no
-- heartbeat could report at all.
--
-- The mapping:
--
--   * @Idle@ is healthy. A processor waiting for messages on a quiet topic is
--     working correctly, and this is the case a heartbeat gets wrong: it cannot
--     beat when there is nothing to process, so an idle consumer would look
--     wedged.
--   * @Processing@ is healthy while its last activity is within the loop's
--     staleness bound, and unhealthy past it. A message in flight for ten
--     minutes is a wedge, and this is the case a bare state check gets wrong.
--   * @Failed@ is unhealthy, dated with the failure's own timestamp rather than
--     the moment of observation.
--   * @Stopped@ is unhealthy. Under @IgnoreFailures@ a stopped processor is a
--     silent death; it is exactly the state this plan exists to surface.
--   * A processor id the supervisor does not know is unhealthy: it means the
--     processor never registered, so nothing is draining the queue.
--
-- The error text from @Failed@ deliberately does not reach the probe body, which
-- carries only the check name. It belongs in the logs.
supervisedLoopVerdict :: LoopName -> Master -> ProcessorId -> IO ProbeVerdict
supervisedLoopVerdict loop master processorId = do
  found <- getProcessorMetricsIO master processorId
  now <- getCurrentTime
  pure (processorStateVerdict loop now found)

-- | The mapping itself, separated from reading it.
--
-- 'supervisedLoopVerdict' is a non-blocking read of a @TVar@ and a clock; every
-- decision worth testing is here, and putting it behind a running supervisor
-- would mean a test could only reach it by standing one up.
processorStateVerdict :: LoopName -> UTCTime -> Maybe ProcessorMetrics -> ProbeVerdict
processorStateVerdict loop now = \case
  Nothing -> Unhealthy (loopCheckName loop) now
  Just ProcessorMetrics {state} -> case state of
    Idle -> Healthy
    Processing _ lastActivity ->
      let deadline = addUTCTime (loopStaleAfter loop) lastActivity
       in if now > deadline then Unhealthy (loopCheckName loop) deadline else Healthy
    Failed _ failedAt -> Unhealthy (loopCheckName loop) failedAt
    Stopped -> Unhealthy (loopCheckName loop) now

-- | Can this process reach PostgreSQL?
--
-- The only readiness dependency any worker role has. Kafka and the downstream
-- HTTP sinks are deliberately excluded: a broker or sink outage cannot be
-- repaired by restarting this process, so making it readiness-critical would
-- amplify one upstream outage across the fleet. Consumer-loop death is reported
-- through liveness instead, which is the probe whose failure means \"restart
-- me\".
postgresReadiness :: Pool -> ProbeCheck
postgresReadiness pool =
  sequenceChecks [boolCheck postgresCheckName (databaseReachable pool)]

-- | Build this process's liveness and readiness checks, in that order.
--
-- Call once at boot. The failure trackers hold state, so rebuilding these per
-- request would make @failingSince@ report the moment of observation instead of
-- the onset of the failure.
mkWorkerHealthChecks :: Pool -> Heartbeats -> IO (ProbeCheck, ProbeCheck)
mkWorkerHealthChecks pool registry = do
  trackLiveness <- newFailureTracker
  trackReadiness <- newFailureTracker
  pure
    ( trackLiveness
        (withProbeTimeout livenessBudgetMicros "liveness" (safeCheck "liveness" (loopLivenessCheck registry))),
      trackReadiness (safeCheck "readiness" (postgresReadiness pool))
    )

-- | How long liveness may take before it is declared failed.
--
-- Two seconds, matching the server's budget. The check itself only reads
-- 'IORef's, so the timeout is not about the check's own cost: it is about a
-- process so wedged that even that does not complete, which is precisely the
-- state liveness exists to catch.
livenessBudgetMicros :: Int
livenessBudgetMicros = 2_000_000

-- ── Serving ─────────────────────────────────────────────────────────────────

-- | The whole of what a worker-role process serves.
--
-- A record with one field rather than the bare @HealthApi@ so that the probes
-- are mounted under @health@ and answer at the same paths the server's do.
newtype WorkerProbeApi mode = WorkerProbeApi
  { health :: mode :- "health" :> NamedRoutes HealthApi
  }
  deriving stock (Generic)

-- | The probe application, given the two checks to mount in that order.
--
-- Separate from 'runProbeListener' so the conformance suite can drive the real
-- assembled application with checks it controls. A builder that ignored its
-- arguments and mounted the process's real checks would prove nothing.
probeApplication :: ProbeCheck -> ProbeCheck -> Application
probeApplication livenessCheck readinessCheck =
  genericServe WorkerProbeApi {health = healthServer livenessCheck readinessCheck}

-- | Serve the probes until the process stops.
--
-- Binds the interface named by @http.host@ — the same key the server binds — so
-- one setting governs whether a development process stays on loopback or a
-- deployed one is reachable by a probe from outside its container.
--
-- Failing to bind is fatal and meant to be: two worker processes configured onto
-- one port must not resolve into one of them silently having no probe. The
-- per-role defaults in @Shikigami.App.Config.defaultHealthPort@ are what keep
-- that from happening by accident.
runProbeListener :: Log.Logger -> Text -> Port -> ProbeCheck -> ProbeCheck -> IO ()
runProbeListener logger bindHost bindPort livenessCheck readinessCheck = do
  Log.logInfo
    logger
    "worker.health.listening"
    [ "host" Aeson..= bindHost,
      "port" Aeson..= portNumber bindPort
    ]
  Warp.runSettings settings (probeApplication livenessCheck readinessCheck)
  where
    settings =
      Warp.setPort (portNumber bindPort)
        . Warp.setHost (fromString (Text.unpack bindHost))
        $ Warp.defaultSettings

-- | Run this role's probe listener alongside the work it exists to do.
--
-- @concurrently_@ rather than a detached thread, and that is the supervision
-- decision in one line: if the listener dies — most likely because its port is
-- already bound — the work is cancelled and the process exits, instead of
-- running on invisibly with no probe. If the work dies, the listener is
-- cancelled and the exception propagates, instead of leaving a socket answering
-- 200 for a process that has stopped doing anything.
--
-- 'Nothing' means this role has no probe port and the work simply runs. That
-- should not happen for a worker role — @defaultHealthPort@ gives all four one —
-- so it is logged rather than passed over in silence.
serveProbesWith :: Log.Logger -> Text -> Maybe Port -> Pool -> Heartbeats -> IO () -> IO ()
serveProbesWith logger bindHost maybePort pool registry work =
  case maybePort of
    Nothing -> do
      Log.logWarn logger "worker.health.disabled" ["reason" Aeson..= ("no health.port resolved for this role" :: Text)]
      work
    Just bindPort -> do
      (livenessCheck, readinessCheck) <- mkWorkerHealthChecks pool registry
      concurrently_ (runProbeListener logger bindHost bindPort livenessCheck readinessCheck) work

-- ── Loop death ──────────────────────────────────────────────────────────────

-- | A loop stopped when it was supposed to run forever.
--
-- Thrown so that the exception escapes into the @concurrently_@ that composes
-- the loops, which cancels the siblings and takes the process down with a
-- non-zero exit. That is the whole supervision strategy: a dead loop must not
-- leave the other three running around a corpse, and an external supervisor
-- restarts a clean process better than this one could restart part of itself.
newtype LoopExited = LoopExited LoopName
  deriving stock (Eq, Show)

instance Exception LoopExited
