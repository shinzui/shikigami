{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- The production fixture belongs to mori://shinzui/rei. with-rei.sh compiles
-- this bridge against the exact pinned source, outside the production closure.
module Main (main) where

import Control.Monad (forM_, unless)
import Data.List (isPrefixOf)
import Data.Text qualified as Text
import Rei.Api.TestSupport.LiveFixture
import System.Environment (getArgs, getEnvironment, setEnv, unsetEnv)
import System.Exit (exitWith)
import System.Process (CreateProcess (..), createProcess, proc, waitForProcess)

main :: IO ()
main = do
  args <- getArgs
  original <- getEnvironment
  let hook = args `elem` [["--hinagata-schema"], ["--hinagata-verify"]]
      keep name = allowed name || name == "REI_API_BIN" || hook && name `elem` ["PGHOST", "PGPORT", "PGUSER", "PGDATABASE"]
  forM_ (filter (not . keep . fst) original) (unsetEnv . fst)
  setEnv "OTEL_SDK_DISABLED" "true"
  liveSchemaHook (runFixture args)

runFixture :: [String] -> IO ()
runFixture args = do
  unless (not (null args)) (fail "with-rei requires a command after --")
  withSharedPostgres $ \database ->
    withLiveFixture database Seed {projectSynced = False, fullViewGraph = True} $ \fixture -> do
      intention <- maybe (fail "Rei fixture has no intention") pure (lookup "graph_intention_id" fixture.variables)
      inherited <- getEnvironment
      let retained = filter (allowed . fst) inherited
          isolated =
            [ ("SHIKIGAMI_TEST_REI_ISOLATED", "masterplan-18"),
              ("SHIKIGAMI_TEST_REI_BASE_URL", Text.unpack fixture.baseUrl),
              ("SHIKIGAMI_TEST_REI_TOKEN", Text.unpack fixture.token),
              ("SHIKIGAMI_TEST_REI_INTENTION", Text.unpack intention),
              ("SHIKIGAMI_TEST_REI_COMMIT", "c109222db550537ec998ecc6fc1866cc7a35e29a")
            ]
      putStrLn "Disposable Rei 8.0.0.0 / typed contract 0.2.0.0; source c109222; loopback only"
      case args of
        command : arguments -> do
          (_, _, _, child) <- createProcess (proc command arguments) {env = Just (isolated <> retained)}
          waitForProcess child >>= exitWith
        _ -> fail "missing child command"

allowed :: String -> Bool
allowed name = name `elem` ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "CABAL_DIR", "CABAL_CONFIG", "PKG_CONFIG_PATH", "LIBRARY_PATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "IN_NIX_SHELL", "GHC_ENVIRONMENT"] || "NIX_" `isPrefixOf` name
