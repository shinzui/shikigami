module Main (main) where

import Shikigami.Workers.Command (runRole, schedulerRoleInfo)

-- | See "Shikigami.Workers.Command" for the role this executable plays.
main :: IO ()
main = runRole schedulerRoleInfo
