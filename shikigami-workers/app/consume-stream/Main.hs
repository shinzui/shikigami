module Main (main) where

import Shikigami.Workers.Command (consumeStreamRoleInfo, runRole)
import Shikigami.Workers.Shutdown (withGracefulShutdown)

-- | See "Shikigami.Workers.Command" for the role this executable plays.
main :: IO ()
main = withGracefulShutdown (runRole consumeStreamRoleInfo)
