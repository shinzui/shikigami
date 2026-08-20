-- | The checks behind @GET \/health\/live@ and @GET \/health\/ready@.
--
-- The route shape comes from "Shikigami.Health.Api"; what \"healthy\" means is
-- decided here.
--
-- Liveness passes unconditionally, which is the honest answer for this process:
-- it runs no background loops, so \"the accept loop, the request parser, and the
-- handler thread are alive\" is the whole of what liveness can mean. The worker
-- roles, which do run loops, answer the same route from their own heartbeat
-- registry in @Shikigami.Health.Worker@.
--
-- Readiness pings PostgreSQL. Deliberately nothing else: Kafka and the
-- downstream HTTP sinks are not readiness dependencies, because a broker outage
-- cannot be repaired by restarting this process or by taking it out of load
-- balancing, and making it readiness-critical would amplify one upstream outage
-- into a fleet-wide one.
--
-- Three hardening decisions are already baked in, because getting them wrong is
-- silent:
--
--   * Every check is wrapped in @safeCheck@. An exception escaping a check would
--     become a 500 with a stack trace instead of a probe report naming the
--     failed dependency.
--   * @withProbeTimeout@ sits /outside/ @safeCheck@ on liveness. The timeout
--     interrupts by throwing an asynchronous exception and @safeCheck@
--     deliberately lets those through; nested the other way round, a deadlocked
--     process would hang its liveness probe instead of failing it — the opposite
--     of what liveness is for.
--   * Each probe gets its own failure tracker, so @failingSince@ reports when a
--     failure began rather than when it was last observed. The trackers hold
--     state, which is why they are built once at boot and stored in the
--     environment rather than rebuilt per request.
module Shikigami.Health.Handler
  ( mkHealthChecks,
  )
where

import Hasql.Pool (Pool)
import Servant.Health (ProbeCheck, ProbeVerdict (Healthy))
import Servant.Health.Check (boolCheck, newFailureTracker, safeCheck, sequenceChecks, withProbeTimeout)
import Shikigami.Health.Ping (databaseReachable, postgresCheckName)

-- | Build the liveness and readiness checks, in that order.
--
-- Call once at boot; the returned actions are run afresh on every probe request.
-- The pool is the one the rest of the process uses, so readiness reflects the
-- same connection path real traffic would take rather than a private connection
-- that could succeed while the application's own pool is exhausted.
mkHealthChecks :: Pool -> IO (ProbeCheck, ProbeCheck)
mkHealthChecks pool = do
  trackLiveness <- newFailureTracker
  trackReadiness <- newFailureTracker
  pure
    ( trackLiveness (withProbeTimeout livenessBudgetMicros "liveness" (safeCheck "liveness" livenessCheck)),
      trackReadiness (safeCheck "readiness" (readinessCheck pool))
    )

-- | How long liveness may take before it is declared failed.
--
-- Two seconds: long enough that a loaded process is not restarted for being
-- slow, short enough that a wedged one is noticed within a couple of probe
-- periods.
livenessBudgetMicros :: Int
livenessBudgetMicros = 2_000_000

-- | Is the process itself still working?
--
-- Answering the request at all is the whole check today: reaching this action
-- means the accept loop, the request parser, and the handler thread are alive.
livenessCheck :: ProbeCheck
livenessCheck = pure Healthy

-- | Can the process serve traffic right now?
--
-- @sequenceChecks@ runs its list left to right and reports the first failure, so
-- order additions cheapest-first. It stays a list of one rather than collapsing
-- to the bare check because the next dependency this server acquires should be
-- appended, not wrapped around.
--
-- No 'withProbeTimeout' here, unlike liveness. The timeout interrupts with an
-- asynchronous exception, which the failure tracker cannot attribute to a named
-- dependency; a slow database should report 503 through its own named check
-- instead. The pool's own acquisition timeout is what bounds this in practice.
readinessCheck :: Pool -> ProbeCheck
readinessCheck pool =
  sequenceChecks [boolCheck postgresCheckName (databaseReachable pool)]
