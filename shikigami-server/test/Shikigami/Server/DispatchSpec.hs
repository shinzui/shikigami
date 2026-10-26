-- | What the server routes is what the document describes.
--
-- @docs\/api\/openapi.json@ is generated from 'Shikigami.Api.shikigamiApi', and
-- the server is built from the same proxy, so the two agree by construction —
-- but only as long as nobody adds a route outside that record, mounts it under a
-- different prefix, or serves a hand-written WAI route beside it. These cases
-- close that gap behaviourally: every documented path is answered by the running
-- server, an undocumented path is not, and the two same-typed probe routes are
-- not transposed.
module Shikigami.Server.DispatchSpec (tests) where

import Data.HashMap.Strict.InsOrd.Compat qualified as InsOrdHashMap
import Data.List (sort)
import Data.OpenApi.Lens qualified as L
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import OpenTelemetry.Trace qualified as Trace
import Servant.Health (ProbeVerdict (Healthy, Unhealthy))
import Servant.Health.Paths (liveRawPath, readyRawPath)
import Shikigami.Agent.Catalog (catalogFromReport)
import Shikigami.Agent.Loader (loadAgentsReport)
import Shikigami.Api.OpenApi (shikigamiOpenApi)
import Shikigami.App.Config (defaultAppConfig)
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Server.App (shikigamiApplication)
import Shikigami.Server.Boot (newServerEnvWith)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "dispatch"
    [ testCase "the documented path set is the served path set" do
        let documented = sort (InsOrdHashMap.keys (shikigamiOpenApi ^. L.paths))
            served = sort (["/agents", "/agents/{agentName}", "/agents/{agentName}/runs", "/agents/{agentName}/runs/{runId}"] <> fmap (Text.unpack . TE.decodeUtf8) [liveRawPath, readyRawPath])
        documented @?= served,
      testCase "every documented path is answered, and an undocumented one is not" do
        let documented = InsOrdHashMap.keys (shikigamiOpenApi ^. L.paths)
        withServer alwaysHealthy alwaysHealthy \get -> do
          mapM_
            ( \path -> do
                status <- get (Text.unpack (Text.replace "{runId}" "dispatch-run" (Text.replace "{agentName}" "heartbeat" (Text.pack path))))
                assertBool (path <> " answered " <> show status <> ", expected a served route") (status /= 404)
            )
            documented
          undocumented <- get "/health"
          undocumented @?= 404,
      testCase "the probe routes are not wired to each other's checks" $
        withServer alwaysHealthy alwaysFailing \get -> do
          live <- get "/health/live"
          ready <- get "/health/ready"
          live @?= 200
          ready @?= 503
    ]

alwaysHealthy :: IO ProbeVerdict
alwaysHealthy = pure Healthy

alwaysFailing :: IO ProbeVerdict
alwaysFailing = pure (Unhealthy "readiness" (UTCTime (fromGregorian 2026 7 31) 0))

-- | Run the assembled application and hand the body a @GET path -> status@ probe.
withServer :: IO ProbeVerdict -> IO ProbeVerdict -> ((String -> IO Int) -> IO a) -> IO a
withServer livenessCheck readinessCheck body = do
  pool <- Pool.acquire (PoolConfig.settings [])
  provider <- Trace.createTracerProvider [] Trace.emptyTracerProviderOptions
  catalog <- catalogFromReport <$> loadAgentsReport "../agents"
  let tracer = Trace.makeTracer provider "shikigami-server-test" Trace.tracerOptions
      application = shikigamiApplication (newServerEnvWith tracer defaultAppConfig pool Log.silentLogger catalog disabledDirectoryHandle livenessCheck readinessCheck)
  testWithApplication (pure application) \port -> do
    manager <- Http.newManager Http.defaultManagerSettings
    body \path -> do
      request <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
      statusCode . Http.responseStatus <$> Http.httpLbs request manager
