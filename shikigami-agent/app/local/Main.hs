module Main (main) where

import Shikigami.Agent.Command (localRoleInfo, runRole)

-- | See "Shikigami.Agent.Command" for the role this executable plays.
main :: IO ()
main = runRole localRoleInfo
