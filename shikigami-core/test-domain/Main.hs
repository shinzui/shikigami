module Main (main) where

import Control.Monad (unless)
import Shikigami.RunEvidence.Conformance (runEvidenceBehaviorReportJson, runEvidenceDomainAssertions)

main :: IO ()
main = do
  mapM_ check runEvidenceDomainAssertions
  putStrLn runEvidenceBehaviorReportJson
  where
    check (label, passed) = do
      unless passed (fail label)
      putStrLn ("PASS " <> label)
