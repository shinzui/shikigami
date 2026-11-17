-- | @shikigami-workspace-supervisor@ composed with the distribution's packs,
-- so governed workspace actions are decided by the Kikan-En authority the
-- Kikan binding registers.
module Main (main) where

import Packs (packs)
import Shikigami.Workers.Command (runRole, workspaceSupervisorRoleInfoWith)

main :: IO ()
main = runRole (workspaceSupervisorRoleInfoWith packs)
