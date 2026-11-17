-- | @shikigami-server@ composed with the distribution's flow packs: it accepts
-- their settings and opens objective tracker connections through the
-- providers they install, such as the binding's Rei provider (plan 135, M4).
module Main (main) where

import Packs (packs)
import Shikigami.Server.Boot (runServerMainWith)

main :: IO ()
main = runServerMainWith packs
