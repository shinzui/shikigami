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

import Data.String (fromString)
import Data.Text qualified as Text
import Network.Wai.Handler.Warp qualified as Warp
import Options.Applicative (execParser)
import Servant.Health (ProbeCheck)
import Shikigami.App.Config (AppConfig, Role (ServerRole))
import Shikigami.App.Config.Load (runAppConfig)
import Shikigami.Health.Handler (mkHealthChecks)
import Shikigami.Server.App (shikigamiApplication)
import Shikigami.Server.Config (ServerConfig (..), serverConfigFrom, serverParserInfo)
import Shikigami.Server.Seam (ServerEnv (..))
import System.IO (hPutStrLn, stderr)

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
newServerEnv :: AppConfig -> IO ServerEnv
newServerEnv config = do
  (livenessCheck, readinessCheck) <- mkHealthChecks
  pure (newServerEnvWith config livenessCheck readinessCheck)

-- | Build the environment with probe checks supplied by the caller.
--
-- Exists for the probe conformance test, which has to be able to fail liveness
-- and readiness independently. Both probe routes have the same handler type, so
-- an umbrella record that swapped them would still compile; only a request that
-- fails one check and not the other catches it, and that requires injecting the
-- checks from outside.
newServerEnvWith :: AppConfig -> ProbeCheck -> ProbeCheck -> ServerEnv
newServerEnvWith config livenessCheck readinessCheck =
  ServerEnv
    { config = serverConfigFrom config,
      appConfig = config,
      liveness = livenessCheck,
      readiness = readinessCheck
    }

-- | Bind the socket and serve until the process is stopped.
--
-- The startup line goes to stderr so that it survives being piped, and names
-- both the bound address and the probe paths an operator will point a health
-- check at.
runServer :: AppConfig -> IO ()
runServer config = do
  env <- newServerEnv config
  let serverConfig = serverConfigFrom config
  hPutStrLn
    stderr
    ( "[shikigami.server] listening on "
        <> Text.unpack (host serverConfig)
        <> ":"
        <> show (port serverConfig)
        <> " (probes: GET /health/live, GET /health/ready)"
    )
  Warp.runSettings (warpSettings serverConfig) (shikigamiApplication env)

warpSettings :: ServerConfig -> Warp.Settings
warpSettings serverConfig =
  Warp.setPort (port serverConfig)
    . Warp.setHost (fromString (Text.unpack (host serverConfig)))
    $ Warp.defaultSettings
