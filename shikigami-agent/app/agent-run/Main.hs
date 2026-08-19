module Main (main) where

import Shikigami.Agent.Command (agentRunRoleInfo, runRole)

-- | See "Shikigami.Agent.Command" for the role this executable plays.
main :: IO ()
main = runRole agentRunRoleInfo
