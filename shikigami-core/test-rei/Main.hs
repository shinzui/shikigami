module Main (main) where

import Shikigami.Migrations.TestSupport (withShikigamiMigratedSuite)
import Shikigami.ObjectiveTrackerReiSpec (dispatchChild, requireIsolatedRei, tests)
import System.Environment (getArgs)
import Test.Tasty (defaultMain)

main :: IO ()
main = do
  args <- getArgs
  if args == ["--tracker-dispatch-and-exit"]
    then dispatchChild
    else do
      connection <- requireIsolatedRei
      withShikigamiMigratedSuite \fixture -> defaultMain (tests fixture connection)
