module Main (main) where

import Data.Text qualified as Text
import Shikigami.Workspace.Collector (runCollector)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import Text.Read (readMaybe)

-- Per-operation coordinates come from the trusted supervisor, never repository
-- configuration. The collector has no command launch or execution grant API.
main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [directory, unit, fingerprint, limit, seconds]
      | Just bytes <- readMaybe limit,
        Just watchdog <- readMaybe seconds -> do
          result <- runCollector directory (Text.pack unit) (Text.pack fingerprint) bytes watchdog
          exitWith (either (const (ExitFailure 70)) (const ExitSuccess) result)
    _ -> exitWith (ExitFailure 64)
