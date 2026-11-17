-- | The @shikigami@ admin command composed with the distribution's flow packs.
module Main (main) where

import Kikan.Shikigami.Stub (stubsPack)
import Packs (packs)
import Shikigami.Server.Command (runAdminWith)

-- | The distribution's packs, and the Kikan service stubs as admin verbs.
main :: IO ()
main = runAdminWith (packs <> [stubsPack])
