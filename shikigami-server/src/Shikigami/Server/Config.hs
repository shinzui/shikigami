-- | The HTTP server's slice of configuration, and how its process obtains it.
--
-- 'ServerConfig' is what the listener needs and nothing more, kept separate from
-- the whole-process 'Shikigami.App.Config.AppConfig' so that the socket's
-- settings live with the socket. It is derived from the resolved configuration
-- rather than resolved separately: there is one declaration for the whole
-- repository, in "Shikigami.App.Config", and this module only projects out the
-- two values Warp is given.
--
-- The rest of the module is the server binary's source assembly. It contributes
-- two operator-friendly flags, @--host@ and @--port@, which are ordinary Settei
-- command-line sources aimed at the declared @http.host@ and @http.port@ keys —
-- so @--port 9000@ and @--set http.port=9000@ mean exactly the same thing, both
-- appear in @--explain-config@ with their spelling, and neither introduces a
-- parser of its own.
module Shikigami.Server.Config
  ( ServerConfig (..),
    defaultServerConfig,
    serverConfigFrom,
    serverParserInfo,
    serverNamedOptions,
  )
where

import Data.Maybe (catMaybes)
import Options.Applicative (Parser, ParserInfo)
import Options.Applicative qualified as Options
import Settei.Optparse (namedOption)
import Settei.Source (Source)
import Shikigami.App.Config
  ( AppConfig (..),
    defaultAppConfig,
    httpHostKey,
    httpPortKey,
    portNumber,
  )
import Shikigami.App.Config.Load (ConfigOptions, withConfigOptions)
import Shikigami.Prelude

-- | Where the public HTTP API listens.
data ServerConfig = ServerConfig
  { -- | TCP port to bind.
    port :: !Int,
    -- | Interface to bind. @\"127.0.0.1\"@ keeps a development server off the
    -- network; @\"*\"@ binds every interface, which is what a container wants.
    host :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | Project the listener's settings out of the resolved configuration.
serverConfigFrom :: AppConfig -> ServerConfig
serverConfigFrom config =
  ServerConfig
    { port = portNumber ((.httpPort) config),
      host = (.httpHost) config
    }

-- | Loopback on port 8080: what the declaration's defaults resolve to, and safe
-- to run on a laptop without exposing anything.
defaultServerConfig :: ServerConfig
defaultServerConfig = serverConfigFrom defaultAppConfig

-- | The @shikigami-server@ command line: configuration and diagnostics only.
serverParserInfo :: ParserInfo ConfigOptions
serverParserInfo =
  snd <$> withConfigOptions "Serve the public Shikigami HTTP API" (pure ()) serverNamedOptions

-- | @--host@ and @--port@ as command-line configuration sources.
serverNamedOptions :: Parser [Source]
serverNamedOptions =
  catMaybes
    <$> sequenceA
      [ namedOption
          "--host"
          httpHostKey
          (Options.long "host" <> Options.metavar "HOST" <> Options.help "Interface to bind (overrides http.host)"),
        namedOption
          "--port"
          httpPortKey
          (Options.long "port" <> Options.metavar "PORT" <> Options.help "TCP port to bind (overrides http.port)")
      ]
