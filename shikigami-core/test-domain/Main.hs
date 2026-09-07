module Main (main) where

import Control.Monad (unless)
import Shikigami.RunEvidence.Conformance (runEvidenceDomainAssertions)

main :: IO ()
main = mapM_ check runEvidenceDomainAssertions
  where
    check (label, passed) = do
      unless passed (fail label)
      putStrLn ("PASS " <> label)
