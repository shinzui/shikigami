-- | @kikan-shikigami-consume-events@: the public integration-event consumer
-- (Danwa's addressed messages, for one), which enqueues matching event agents.
module Main (main) where

import Kikan.Shikigami.Binding.Intake.Role (consumeEventsRoleInfo)
import Packs (packs)
import Shikigami.Workers.Command (runRole)
import Shikigami.Workers.Shutdown (withGracefulShutdown)

main :: IO ()
main = withGracefulShutdown (runRole (consumeEventsRoleInfo packs))
