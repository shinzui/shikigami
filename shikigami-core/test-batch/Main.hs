-- The fixture deliberately shares its cases with the ordinary core suite.
module Main (main) where

import Control.Monad (forM_)
import Shikigami.Behavior.BatchCliFixture (cancellationCases)
import System.Info (arch, os)

main :: IO ()
main = do
  putStrLn ("Batch CLI inherited-group qualification: " <> os <> "/" <> arch)
  forM_ cancellationCases \(name, run) -> do
    run
    putStrLn ("PASS " <> name)
  putStrLn ("PASS " <> show (length cancellationCases) <> " lifecycle cases; batch bounds/confinement remain unqualified")
