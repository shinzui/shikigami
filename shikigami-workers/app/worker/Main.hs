module Main (main) where

import Shikigami.Workers.Command (runRole, workerRoleInfo)

-- | See "Shikigami.Workers.Command" for the role this executable plays.
main :: IO ()
main = runRole workerRoleInfo
