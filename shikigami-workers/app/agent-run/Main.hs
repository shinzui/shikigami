module Main (main) where

import Shikigami.Workers.Command (agentRunRoleInfo, runRole)

-- | See "Shikigami.Workers.Command" for the role this executable plays.
main :: IO ()
main = runRole agentRunRoleInfo
