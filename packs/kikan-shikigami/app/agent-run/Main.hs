-- | @shikigami-agent-run@ composed with the distribution's flow packs.
module Main (main) where

import Packs (packs)
import Shikigami.Agent.Command (agentRunRoleInfoWith, runRole)

main :: IO ()
main = runRole (agentRunRoleInfoWith packs)
