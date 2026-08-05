module Shikigami.Workers.Command.RunBehavior
  ( runRunBehavior,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Text (encodeToLazyText)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.Lazy.IO qualified as TLIO
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.Behavior.Provider (newBehaviorEnvFor)
import Shikigami.Behavior.Run (runBehavior, triggerOnly)
import Shikigami.Log qualified as Log
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @run-behavior --agent <file> [--payload <json>]@: load a manifest, run its
-- behavior, and print the output JSON.
--
-- It opens no database and joins no queue, which makes it the cheapest way to
-- exercise a provider end to end: with @behavior.provider@ unset it prints the
-- stub's fixed sentence, and with the Anthropic branch configured it is a single
-- real model call. The provider line on standard error says which of those just
-- happened, so the two are never confused. That line is a structured
-- @behavior.provider.selected@ event on standard error; the command's own output
-- stays on standard out, so piping the result to @jq@ is unaffected.
runRunBehavior :: FilePath -> Maybe String -> AppConfig -> IO ()
runRunBehavior path mpayload config = do
  logger <- Log.newStderrLogger Log.Info
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
      env <- newBehaviorEnvFor logger (Config.behaviorProvider config) Nothing
      -- No recalled memories: recall needs a database and this command opens
      -- none, so the behavior runs on the trigger payload alone.
      resultE <- runBehavior env decl (triggerOnly payload)
      case resultE of
        Left runErr -> do
          hPutStrLn stderr ("run-behavior: " <> show runErr)
          exitFailure
        Right v -> TLIO.putStrLn (encodeToLazyText v)
