-- | The health vertical's public route tree.
--
-- Kubernetes distinguishes two probes. A /liveness/ probe answers \"is this
-- process still working?\"; when it fails, the container is restarted. A
-- /readiness/ probe answers \"can this process serve traffic right now?\"; when
-- it fails, the pod is only removed from load balancing. Collapsing them into a
-- single @\/health@ route would throw away that distinction, so there are two
-- routes and no combined one.
--
-- The shape is not invented here. @servant-health@ is the fleet's released
-- package for exactly this surface: a fixed probe body, typed 200 and 503
-- alternatives expressed with @MultiVerb@, and an injectable check seam. This
-- module is the Shikigami-owned name for it, so that later work — notably
-- @docs\/plans\/29-health-liveness-and-worker-loop-supervision.md@, which adds the
-- real checks — extends one module rather than restating the route type.
--
-- Mounted by 'Shikigami.Api.ShikigamiApi' under the @health@ segment, which
-- makes the served paths @GET \/health\/live@ and @GET \/health\/ready@.
--
-- Probe bodies are deliberately exempt from the RFC 7807 problem-details rule in
-- "Shikigami.Api.Problem": a 503 from a readiness probe is a status report about
-- the service, not an error about the request, and monitoring reads it with the
-- same parser it uses for the 200.
module Shikigami.Health.Api
  ( -- * Routes
    HealthApi (..),
    ProbeResponses,
    ProbeResult (..),

    -- * Wire contract
    ProbeStatus (..),
    probeJsonOptions,

    -- * Check seam
    ProbeCheck,
    ProbeVerdict (..),

    -- * Raw paths
    healthMountSegment,
    liveRawPath,
    readyRawPath,
    healthRawPaths,
  )
where

import Servant.Health
  ( HealthApi (..),
    ProbeCheck,
    ProbeResponses,
    ProbeResult (..),
    ProbeStatus (..),
    ProbeVerdict (..),
    probeJsonOptions,
  )
import Servant.Health.Paths
  ( healthMountSegment,
    healthRawPaths,
    liveRawPath,
    readyRawPath,
  )
