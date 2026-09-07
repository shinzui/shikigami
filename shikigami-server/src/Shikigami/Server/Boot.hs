-- | Starting and stopping the HTTP server process.
--
-- Everything with a lifetime is created here and nowhere else: the probe
-- checks (which hold failure-onset state), the environment handlers read, and
-- the listening socket. Handlers receive what they need through
-- 'Shikigami.Server.Seam.ServerEnv' rather than creating resources per request.
--
-- This process serves the public HTTP API and nothing else. It starts no queue
-- workers, no stream consumers, and no schedulers — those are separate
-- executables in @shikigami-workers@, and keeping them separate is what lets an
-- operator scale, restart, or roll out the API independently of the background
-- loops.
module Shikigami.Server.Boot
  ( runServerMain,
    runServer,
    newServerEnv,
    newServerEnvWith,
  )
where

import Data.Aeson qualified as Aeson
import Data.String (fromString)
import Data.Text qualified as Text
import Hasql.Pool (Pool)
import Kiroku.Store.Connection qualified as StoreConnection
import Network.Wai (Application)
import Network.Wai.Handler.Warp qualified as Warp
import OpenTelemetry.Instrumentation.Wai (newOpenTelemetryWaiMiddleware')
import OpenTelemetry.Metric qualified as Metric
import OpenTelemetry.Trace.Core (Tracer)
import Options.Applicative (execParser)
import Servant.Health (ProbeCheck)
import Shikigami.App.Config (AppConfig, Role (ServerRole), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl, runAppConfig)
import Shikigami.Health.Handler (mkHealthChecks)
import Shikigami.Log qualified as Log
import Shikigami.Server.App (exceptionBoundary, shikigamiApplication)
import Shikigami.Server.Config (ServerConfig (..), serverConfigFrom, serverParserInfo)
import Shikigami.Server.RequestLog (includeProductionRequest, requestLogMiddleware)
import Shikigami.Server.Seam (ServerEnv (..))
import Shikigami.Server.Telemetry (ServerTelemetry (..), boundedTelemetryMiddleware, withServerTelemetry)
import System.Posix.Signals (Handler (CatchOnce), installHandler, keyboardSignal, softwareTermination)

-- | The @shikigami-server@ executable, start to finish.
--
-- Parse, resolve configuration, then serve. Nothing with a lifetime is created
-- before 'runAppConfig' returns, so @--check-config@ and both
-- @--describe-config@ forms complete without binding a socket.
runServerMain :: IO ()
runServerMain = do
  options <- execParser serverParserInfo
  config <- runAppConfig ServerRole options
  runServer config

-- | Build the environment handlers read, creating the stateful probe checks once.
--
-- The pool is passed in rather than opened here because it has a lifetime:
-- 'runServer' brackets it around the whole serving loop, so it is closed on
-- shutdown instead of being leaked by whoever happened to build the environment.
newServerEnv :: Tracer -> Pool -> AppConfig -> IO ServerEnv
newServerEnv tracer pool config = do
  (livenessCheck, readinessCheck) <- mkHealthChecks pool
  pure (newServerEnvWith tracer config livenessCheck readinessCheck)

-- | Build the environment with probe checks supplied by the caller.
--
-- Exists for the probe conformance test, which has to be able to fail liveness
-- and readiness independently. Both probe routes have the same handler type, so
-- an umbrella record that swapped them would still compile; only a request that
-- fails one check and not the other catches it, and that requires injecting the
-- checks from outside.
newServerEnvWith :: Tracer -> AppConfig -> ProbeCheck -> ProbeCheck -> ServerEnv
newServerEnvWith tracer config livenessCheck readinessCheck =
  ServerEnv
    { config = serverConfigFrom config,
      appConfig = config,
      tracer,
      liveness = livenessCheck,
      readiness = readinessCheck
    }

-- | Bind the socket and serve until the process is stopped.
--
-- The connection pool is opened before the listener and closed after it, because
-- readiness pings PostgreSQL through the same pool the rest of the process uses.
-- Opening it here rather than inside a handler is what lets a probe report
-- \"the database is unreachable\" instead of \"this request could not get a
-- connection\".
--
-- The startup line goes to stderr so that it survives being piped, and names
-- both the bound address and the probe paths an operator will point a health
-- check at.
runServer :: AppConfig -> IO ()
runServer config = do
  logger <- Log.newStderrLogger Log.Info
  connStr <- revealSecretText <$> requireDatabaseUrl "shikigami-server" config
  let serverConfig = serverConfigFrom config
      settings = StoreConnection.defaultConnectionSettings connStr
  withServerTelemetry \telemetry@ServerTelemetry {tracer = serverTracer} ->
    StoreConnection.withStore settings \st -> do
      env <- newServerEnv serverTracer (StoreConnection.pool st) config
      application <- serverApplication telemetry env
      Log.logInfo
        logger
        "server.listening"
        [ "host" Aeson..= (.host) serverConfig,
          "port" Aeson..= (.port) serverConfig,
          "probes" Aeson..= (["/health/live", "/health/ready"] :: [Text.Text])
        ]
      Warp.runSettings (warpSettings serverConfig) application

serverApplication :: ServerTelemetry -> ServerEnv -> IO Application
serverApplication ServerTelemetry {tracerProvider, meterProvider} env = do
  meter <- Metric.getMeter meterProvider "hs-opentelemetry-instrumentation-wai"
  otelMiddleware <- newOpenTelemetryWaiMiddleware' tracerProvider meter
  pure
    ( boundedTelemetryMiddleware
        otelMiddleware
        ( requestLogMiddleware
            includeProductionRequest
            (exceptionBoundary (shikigamiApplication env))
        )
    )

warpSettings :: ServerConfig -> Warp.Settings
warpSettings serverConfig =
  Warp.setInstallShutdownHandler installShutdownHandlers
    . Warp.setGracefulShutdownTimeout (Just 30)
    . Warp.setPort ((.port) serverConfig)
    . Warp.setHost (fromString (Text.unpack ((.host) serverConfig)))
    $ Warp.defaultSettings

-- | Close the listener on either conventional graceful process signal.
-- Warp then drains in-flight requests before 'runSettings' returns, allowing
-- the enclosing telemetry bracket to flush and shut providers down.
installShutdownHandlers :: IO () -> IO ()
installShutdownHandlers closeListener = do
  _ <- installHandler softwareTermination (CatchOnce closeListener) Nothing
  _ <- installHandler keyboardSignal (CatchOnce closeListener) Nothing
  pure ()
