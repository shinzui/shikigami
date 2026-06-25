module Shikigami.Cli.Commands.RunBehavior
  ( runRunBehavior,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Text (encodeToLazyText)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.Lazy.IO qualified as TLIO
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Behavior.Run (newBehaviorEnv, runBehavior)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @run-behavior --agent <file> [--payload <json>]@: load a manifest, run its
-- behavior with deterministic stubs (no DB, no key), and print the output JSON.
runRunBehavior :: FilePath -> Maybe String -> IO ()
runRunBehavior path mpayload = do
  payload <- case mpayload of
    Nothing -> pure Aeson.Null
    Just raw -> case Aeson.decodeStrict (TE.encodeUtf8 (Text.pack raw)) of
      Just v -> pure v
      Nothing -> do
        hPutStrLn stderr ("run-behavior: --payload is not valid JSON: " <> raw)
        exitFailure
  declE <- loadAgent path
  case declE of
    Left err -> do
      hPutStrLn stderr ("run-behavior: load error in " <> path <> ": " <> show err)
      exitFailure
    Right decl -> do
      env <- newBehaviorEnv
      resultE <- runBehavior env decl payload
      case resultE of
        Left runErr -> do
          hPutStrLn stderr ("run-behavior: " <> show runErr)
          exitFailure
        Right v -> TLIO.putStrLn (encodeToLazyText v)
