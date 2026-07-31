module Main (main) where

import Shikigami.SchedulerSpec qualified as SchedulerSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "shikigami-workers"
        [ SchedulerSpec.tests
        ]
    )
