-- | @shikigami-agent-run@ composed with the examples pack.
module Main (main) where

import FlowPack.Examples (examplesPack)
import Shikigami.Agent.Command (agentRunRoleInfoWith, runRole)

main :: IO ()
main = runRole (agentRunRoleInfoWith [examplesPack])
