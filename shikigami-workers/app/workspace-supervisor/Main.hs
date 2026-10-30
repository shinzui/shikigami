module Main (main) where

import Shikigami.Workers.Command (runRole, workspaceSupervisorRoleInfo)

main :: IO ()
main = runRole workspaceSupervisorRoleInfo
