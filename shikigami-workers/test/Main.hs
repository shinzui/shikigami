module Main (main) where

import Shikigami.SchedulerSpec qualified as SchedulerSpec
import Shikigami.Workers.CommandSpec qualified as CommandSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "shikigami-workers"
        [ CommandSpec.tests,
          SchedulerSpec.tests
        ]
    )
