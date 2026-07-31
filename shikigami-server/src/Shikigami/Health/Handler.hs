-- | The checks behind @GET \/health\/live@ and @GET \/health\/ready@.
--
-- The route shape comes from "Shikigami.Health.Api"; what \"healthy\" means is
-- decided here. Both probes currently pass unconditionally, which is honest for
-- a server that has no dependencies to be unhealthy about: it serves one static
-- route and holds no database handle. Real checks — database reachability,
-- queue depth, subscription lag — arrive with
-- @docs\/plans\/29-health-liveness-and-worker-loop-supervision.md@, and the
-- structure below is what they slot into.
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

import Servant.Health (ProbeCheck, ProbeVerdict (Healthy))
import Servant.Health.Check (newFailureTracker, safeCheck, sequenceChecks, withProbeTimeout)

-- | Build the liveness and readiness checks, in that order.
--
-- Call once at boot; the returned actions are run afresh on every probe request.
mkHealthChecks :: IO (ProbeCheck, ProbeCheck)
mkHealthChecks = do
  trackLiveness <- newFailureTracker
  trackReadiness <- newFailureTracker
  pure
    ( trackLiveness (withProbeTimeout livenessBudgetMicros "liveness" (safeCheck "liveness" livenessCheck)),
      trackReadiness (safeCheck "readiness" readinessCheck)
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
-- The empty list is the extension point: add one check per dependency the server
-- needs before it should receive traffic. @sequenceChecks@ runs them left to
-- right and reports the first failure, so order them cheapest-first.
readinessCheck :: ProbeCheck
readinessCheck = sequenceChecks []
