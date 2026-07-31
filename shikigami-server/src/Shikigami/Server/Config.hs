-- | Settings the HTTP server process needs before it can bind a socket.
--
-- This is the server's slice of process configuration, kept separate from
-- "Shikigami.App.Config" (the whole-process value in @shikigami-core@) so that
-- the listener's settings live with the listener. Resolution — where the values
-- come from, in what precedence, with what diagnostics on a bad value — is owned
-- by @docs\/plans\/37-adopt-settei-configuration-across-shikigami-binaries.md@.
-- Until that lands, 'defaultServerConfig' supplies the values and nothing here
-- reads the environment.
module Shikigami.Server.Config
  ( ServerConfig (..),
    defaultServerConfig,
  )
where

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

-- | Loopback on port 8080: safe to run on a laptop without exposing anything.
defaultServerConfig :: ServerConfig
defaultServerConfig =
  ServerConfig
    { port = 8080,
      host = "127.0.0.1"
    }
