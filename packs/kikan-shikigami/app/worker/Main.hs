-- | @shikigami-worker@ composed with the distribution's flow packs.
module Main (main) where

import Packs (packs)
import Shikigami.Workers.Command (runRole, workerRoleInfoWith)
import Shikigami.Workers.Shutdown (withGracefulShutdown)

main :: IO ()
main = withGracefulShutdown (runRole (workerRoleInfoWith packs))
