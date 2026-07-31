module Main (main) where

import Shikigami.Server.Boot (runServer)
import Shikigami.Server.Config (defaultServerConfig)

-- | @shikigami-server@: serve the public HTTP API.
--
-- Configuration is the built-in default until
-- @docs\/plans\/37-adopt-settei-configuration-across-shikigami-binaries.md@
-- supplies resolved settings.
main :: IO ()
main = runServer defaultServerConfig
