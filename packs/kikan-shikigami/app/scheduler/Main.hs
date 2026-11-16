-- | @shikigami-scheduler@ composed with the distribution's flow packs, so a
-- pack's schedule hook decides whether a due tick runs under an enrolled
-- resource root.
module Main (main) where

import Packs (packs)
import Shikigami.Workers.Command (runRole, schedulerRoleInfoWith)
import Shikigami.Workers.Shutdown (withGracefulShutdown)

main :: IO ()
main = withGracefulShutdown (runRole (schedulerRoleInfoWith packs))
