module Main (main) where

import Shikigami.Agent.Capability.OneOffSpec qualified as OneOffSpec
import Shikigami.Agent.Capability.WorkspaceSpec qualified as WorkspaceSpec
import Shikigami.Agent.CommandSpec qualified as CommandSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain (testGroup "shikigami-agent" [CommandSpec.tests, WorkspaceSpec.tests, OneOffSpec.tests])
