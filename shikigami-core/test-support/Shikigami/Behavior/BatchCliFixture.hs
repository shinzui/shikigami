-- | Shared public-adapter lifecycle proofs. The ordinary core suite and the
-- standalone native Linux fixture execute these exact cases. No credentials or
-- vendor installations are needed; this qualifies inherited groups only.
module Shikigami.Behavior.BatchCliFixture (cliModel, withFake, cancellationCases) where

import Baikai.Api (Api (..))
import Baikai.Context (emptyContext)
import Baikai.Evidence qualified as Evidence
import Baikai.Model (Model, emptyModel)
import Baikai.Options (emptyOptions)
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Baikai.Provider.OpenAI.Cli qualified as CodexCli
import Baikai.Provider.Registry (ApiProvider (..))
import Baikai.ResponseFormat (ResponseFormat (JsonSchema), jsonSchemaFormat)
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (AsyncException (ThreadKilled), SomeException, bracket, finally, fromException, try)
import Control.Lens ((&), (.~))
import Control.Monad (unless, void)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text (Text)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Directory (createDirectory, doesFileExist, executable, getPermissions, getTemporaryDirectory, removeDirectoryRecursive, removeFile, setPermissions)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)
import System.Process qualified as Process
import System.Timeout (timeout)

check :: String -> Bool -> IO ()
check label passed = unless passed (fail label)

cancellationCases :: [(String, IO ())]
cancellationCases =
  [ (show api <> suffix, cancellationCase api streaming resistant version)
  | api <- [AnthropicMessagesCli, OpenAICompletionsCli],
    (streaming, resistant, version, suffix) <-
      [ (False, False, False, "/complete"),
        (False, True, False, "/complete-resistant-repeated"),
        (True, True, False, "/stream-resistant-repeated"),
        (False, True, True, "/version-probe")
      ]
  ]

cliModel :: Api -> Model
cliModel apiTag = (emptyModel & #api .~ (apiTag) & #provider .~ (if apiTag == AnthropicMessagesCli then "anthropic" else "openai") & #modelId .~ ("explicit-fake-model"))

withFake :: String -> (FilePath -> FilePath -> IO a) -> IO a
withFake body run = bracket acquire removeDirectoryRecursive \dir -> do
  let exe = dir </> "vendor"
  writeFile exe ("#!/bin/sh\n" <> body)
  permissions <- getPermissions exe
  setPermissions exe permissions {executable = True}
  run dir exe
  where
    acquire = do
      tmp <- getTemporaryDirectory
      (path, handle) <- openTempFile tmp "shikigami-baikai-test"
      hClose handle
      removeFile path
      createDirectory path
      pure path

-- Synchronize on the owned child before cancellation, then require the original
-- asynchronous exception and complete descendant settlement. This qualifies
-- inherited group cancellation; batch deadlines/output/confinement stay gated.
cancellationCase :: Api -> Bool -> Bool -> Bool -> IO ()
cancellationCase apiTag streaming resistant version = withFake body \dir exe -> bracket (Process.createProcess (Process.proc "sleep" ["30"])) (\(_, _, _, sentinel) -> Process.terminateProcess sentinel >> void (Process.waitForProcess sentinel)) \(_, _, _, sentinel) -> do
  finished <- newEmptyMVar
  let provider =
        if apiTag == AnthropicMessagesCli
          then ClaudeCli.claudeCliProvider ((ClaudeCli.defaultClaudeCliConfig & #executable .~ (exe) & #workingDir .~ (Just dir)))
          else CodexCli.codexCliProvider ((CodexCli.defaultCodexCliConfig & #executable .~ (exe) & #workingDir .~ (Just dir)))
      options =
        emptyOptions
          & #evidence .~ (if version then Just (Evidence.evidenceRequest "version-cancellation") else Nothing)
          & #responseFormat .~ (if apiTag == OpenAICompletionsCli && not version then Just (JsonSchema (jsonSchemaFormat "public" (Aeson.object ["type" .= ("object" :: Text)]))) else Nothing)
      run = if streaming then Stream.fold Fold.drain (provider.stream (cliModel apiTag) emptyContext options) else void (provider.complete (cliModel apiTag) emptyContext options)
  worker <- forkIO (try @SomeException run >>= putMVar finished)
  let cleanup = do
        mapM_
          ( \file -> do
              exists <- doesFileExist (dir </> file)
              if exists then readFile (dir </> file) >>= \pid -> void (readProcessWithExitCode "/bin/kill" ["-KILL", takeWhile (/= '\n') pid] "") else pure ()
          )
          ["child", "parent"]
        void (timeout 6_000_000 (takeMVar finished))
  flip finally cleanup do
    ready <- timeout 2_000_000 (waitFor (dir </> "child"))
    unless (ready == Just ()) (fail "fake process did not start")
    void (forkIO (killThread worker))
    whenResistant (void (forkIO (threadDelay 10_000 >> killThread worker)))
    result <- timeout 2_000_000 (readMVar finished)
    case result of
      Just (Left failure) -> check "original asynchronous exception" (fromException @AsyncException failure == Just ThreadKilled)
      _ -> fail "cancellation did not settle and propagate ThreadKilled"
    mapM_
      ( \file -> do
          pid <- takeWhile (/= '\n') <$> readFile (dir </> file)
          gone <- timeout 2_000_000 (waitForStopped pid)
          check (file <> " stopped") (gone == Just ())
      )
      ["parent", "child"]
    Process.getProcessExitCode sentinel >>= \status -> check "unrelated sentinel alive" (status == Nothing)
    schemaExists <- doesFileExist (dir </> "schema-path")
    if schemaExists
      then do
        path <- takeWhile (/= '\n') <$> readFile (dir </> "schema-path")
        doesFileExist path >>= \exists -> check "Codex schema removed" (not exists)
      else unless (version || apiTag /= OpenAICompletionsCli) (fail "Codex schema path was not captured")
  where
    whenResistant action = if resistant then action else pure ()
    body =
      "cd \"$(dirname \"$0\")\"\n"
        <> "if [ \"$1\" = --version ]; then\n"
        <> (if version then "  :\n" else "  echo public-fixture-1; exit 0\n")
        <> "else\n"
        <> ( if version
               then
                 if apiTag == AnthropicMessagesCli
                   then "  printf '%s\\n' '{\"result\":\"marker\",\"is_error\":false}'; exit 0\n"
                   else "  printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"marker\"}}'; exit 0\n"
               else "  while [ $# -gt 0 ]; do if [ \"$1\" = --output-schema ]; then shift; echo \"$1\" > schema-path; fi; shift; done\n"
           )
        <> "fi\n"
        <> (if resistant then "trap '' TERM INT\n" else "")
        <> "echo $$ > parent\nsleep 30 &\necho $! > child\nwait\n"
    waitFor path = do
      exists <- doesFileExist path
      ready <- if exists then not . null <$> readFile path else pure False
      if ready then pure () else threadDelay 10_000 >> waitFor path
    waitForStopped pid = do
      (status, state, _) <- readProcessWithExitCode "/bin/ps" ["-o", "stat=", "-p", pid] ""
      if status /= ExitSuccess || 'Z' `elem` state then pure () else threadDelay 10_000 >> waitForStopped pid
