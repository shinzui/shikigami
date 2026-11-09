{-# LANGUAGE GHC2024 #-}

-- Reuse the owning suite against the production module compiled in this workspace.
module Main (main) where

import Shikigami.ExecutionResourcesSpec qualified as Resources
import Test.Tasty (defaultMain)

main :: IO ()
main = defaultMain Resources.tests
