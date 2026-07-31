module Main (main) where

import Shikigami.Server.Boot (runServerMain)

-- | @shikigami-server@: serve the public HTTP API.
main :: IO ()
main = runServerMain
