-- | @shikigami-consume-stream@ composed with the distribution's flow packs,
-- so a pack's stream hook has its say over the records that match its flows.
module Main (main) where

import Packs (packs)
import Shikigami.Workers.Command (consumeStreamRoleInfoWith, runRole)
import Shikigami.Workers.Shutdown (withGracefulShutdown)

main :: IO ()
main = withGracefulShutdown (runRole (consumeStreamRoleInfoWith packs))
