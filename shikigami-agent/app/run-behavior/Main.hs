module Main (main) where

import Shikigami.Agent.Command (runBehaviorRoleInfo, runRole)

-- | See "Shikigami.Agent.Command" for the role this executable plays.
main :: IO ()
main = runRole runBehaviorRoleInfo
