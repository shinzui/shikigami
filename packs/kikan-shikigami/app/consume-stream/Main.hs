-- | @kikan-shikigami-consume-stream@: the Kawa activity stream consumer,
-- composed with the distribution's flow packs so a pack's stream hook has its
-- say over the records that match its flows.
module Main (main) where

import Kikan.Shikigami.Binding.Intake.Role (consumeStreamRoleInfo)
import Packs (packs)
import Shikigami.Workers.Command (runRole)
import Shikigami.Workers.Shutdown (withGracefulShutdown)

main :: IO ()
main = withGracefulShutdown (runRole (consumeStreamRoleInfo packs))
