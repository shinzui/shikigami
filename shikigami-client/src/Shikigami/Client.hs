-- | Calling a running Shikigami server, without writing any HTTP by hand.
--
-- The functions here are not written; they are /derived/ from
-- 'Shikigami.Api.ShikigamiApi' — the same route record the server is built from
-- and the OpenAPI document is generated from. @genericClient@ reads that record
-- and produces one function per endpoint, with the argument and result types the
-- route declares.
--
-- The consequence worth stating plainly: a client call that does not match the
-- served route does not compile. There is no URL string to mistype, no status
-- code to forget, no body shape to drift. When a route changes, every caller
-- fails to build rather than failing at run time against a deployed server.
--
-- A call is a value in @ClientM@, Servant's client monad. Running one needs a
-- 'ClientEnv' — an HTTP connection manager plus the server's base URL — which
-- 'clientEnvFor' builds from a URL string. 'callServer' does both.
module Shikigami.Client
  ( -- * Endpoints
    shikigamiClient,
    healthClient,
    agentsClient,

    -- * Running a call
    clientEnvFor,
    callServer,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Servant.Client (ClientEnv, ClientError, ClientM, mkClientEnv, parseBaseUrl, runClientM)
import Servant.Client.Generic (AsClientT, genericClient)
import Shikigami.Agent.Api (AgentApi)
import Shikigami.Api (ShikigamiApi (..))
import Shikigami.Health.Api (HealthApi)

-- | Every endpoint, as a record of callable functions.
shikigamiClient :: ShikigamiApi (AsClientT ClientM)
shikigamiClient = genericClient

-- | The health endpoints, reached through the same mount the server uses.
--
-- Written as its own binding so callers say @live healthClient@ rather than
-- reaching through the umbrella record every time.
healthClient :: HealthApi (AsClientT ClientM)
healthClient = (.health) shikigamiClient

-- | Build the environment a call runs in from a server base URL.
--
-- Throws with the parse error if the URL is not a valid base URL: a bad
-- @--server@ value should stop the program with a clear message rather than
-- surface later as a confusing connection failure.
clientEnvFor :: Text -> IO ClientEnv
clientEnvFor url = do
  baseUrl <- parseBaseUrl (Text.unpack url)
  manager <- newManager tlsManagerSettings
  pure (mkClientEnv manager baseUrl)

-- | Run one call against the server at the given base URL.
callServer :: Text -> ClientM a -> IO (Either ClientError a)
callServer url call = do
  env <- clientEnvFor url
  runClientM call env

agentsClient :: AgentApi (AsClientT ClientM)
agentsClient = (.agents) shikigamiClient
