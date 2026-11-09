-- Run inside `cabal exec` so imported dependencies use the project's solved units.
-- Explicit home modules and -i keep unrelated source out of this focused build.
module Main (main) where

import Control.Monad (unless)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Process (callProcess)

main :: IO ()
main = do
  environment <- lookupEnv "GHC_ENVIRONMENT"
  unless (maybe False (not . null) environment) (fail "run Heni through cabal exec after building shikigami-core-test")
  createDirectoryIfMissing True ".heni-build"
  callProcess
    "ghc"
    [ "--make",
      "-fforce-recomp",
      "-O0",
      "-i",
      "-XGHC2024",
      "-XBlockArguments",
      "-XDeriveAnyClass",
      "-XDuplicateRecordFields",
      "-XMultilineStrings",
      "-XNoFieldSelectors",
      "-XOverloadedLabels",
      "-XOverloadedRecordDot",
      "-XOverloadedStrings",
      "-outputdir",
      ".heni-build",
      "-o",
      ".heni-build/resources",
      "tests/mutation/Main.hs",
      "shikigami-core/src/Shikigami/Execution/Resources.hs",
      "shikigami-core/test/Shikigami/ExecutionResourcesSpec.hs"
    ]
