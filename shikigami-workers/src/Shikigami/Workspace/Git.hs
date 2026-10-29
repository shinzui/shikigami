-- | Trusted provider Git plumbing only. This is not a model command runner.
module Shikigami.Workspace.Git (runWorkspaceGit) where

import Control.Exception (IOException, catch)
import Data.ByteString qualified as Bytes
import Data.Maybe (fromMaybe)
import Shikigami.Workspace.Types (WorkspaceError (..))
import System.Exit (ExitCode (..))
import System.IO (IOMode (..), withFile)
import System.Process (CreateProcess (..), StdStream (..), proc, terminateProcess, waitForProcess, withCreateProcess)
import System.Timeout (timeout)

-- Bound capture and runtime; discard stderr rather than risking raw diagnostics.
-- All child environment is controlled, including config and credential lookup.
runWorkspaceGit :: FilePath -> Int -> [String] -> IO (Either WorkspaceError Bytes.ByteString)
runWorkspaceGit root limit args = catch (fromMaybe (Left WorkspaceAllocationRefused) <$> timeout 60000000 work) (\(_ :: IOException) -> pure (Left WorkspaceAllocationRefused))
  where
    work = withFile "/dev/null" WriteMode \sink ->
      withCreateProcess
        ( (proc "git" (["-c", "core.hooksPath=/dev/null", "-c", "protocol.file.allow=always"] <> args))
            { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", root), ("GIT_CONFIG_NOSYSTEM", "1"), ("GIT_CONFIG_GLOBAL", "/dev/null"), ("GIT_TERMINAL_PROMPT", "0")],
              std_in = NoStream,
              std_out = CreatePipe,
              std_err = UseHandle sink
            }
        )
        \_ output _ process -> case output of
          Nothing -> pure (Left WorkspaceAllocationRefused)
          Just handle -> do
            let readBounded total chunks = do
                  chunk <- Bytes.hGetSome handle 8192
                  if Bytes.null chunk
                    then pure (Just (Bytes.concat (reverse chunks)))
                    else
                      if total + Bytes.length chunk > limit
                        then pure Nothing
                        else readBounded (total + Bytes.length chunk) (chunk : chunks)
            bounded <- readBounded 0 []
            case bounded of
              Nothing -> terminateProcess process >> waitForProcess process >> pure (Left WorkspaceAllocationRefused)
              Just bytes -> do
                status <- waitForProcess process
                pure (if status == ExitSuccess then Right bytes else Left WorkspaceAllocationRefused)
