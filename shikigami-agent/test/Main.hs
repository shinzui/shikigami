module Main (main) where

import Shikigami.Agent.CommandSpec qualified as CommandSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain (testGroup "shikigami-agent" [CommandSpec.tests])
