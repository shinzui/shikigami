-- | The @shikigami@ admin command composed with the distribution's flow packs.
module Main (main) where

import Packs (packs)
import Shikigami.Server.Command (runAdminWith)

main :: IO ()
main = runAdminWith packs
