-- | Trusted provider Git plumbing only. This is not a model command runner.
module Shikigami.Workspace.Git (runWorkspaceGit, runWorkspaceGitInput) where

import Control.Concurrent.Async (wait, withAsync)
import Control.Exception (IOException, catch, finally)
import Data.ByteString qualified as Bytes
import Data.Maybe (fromMaybe)
import Shikigami.Workspace.Types (WorkspaceError (..))
import System.Exit (ExitCode (..))
import System.IO (IOMode (..), hClose, withFile)
import System.Process (CreateProcess (..), StdStream (..), proc, terminateProcess, waitForProcess, withCreateProcess)
import System.Timeout (timeout)

-- Bound capture and runtime; discard stderr rather than risking raw diagnostics.
-- All child environment is controlled, including config and credential lookup.
runWorkspaceGit :: FilePath -> Int -> [String] -> IO (Either WorkspaceError Bytes.ByteString)
runWorkspaceGit root limit args = runGit root limit [] args Nothing

-- Trusted object plumbing supplies only fixed author/date environment entries.
-- Bytes travel over stdin, never argv, diagnostics or a repository-owned file.
runWorkspaceGitInput :: FilePath -> Int -> [(String, String)] -> [String] -> Bytes.ByteString -> IO (Either WorkspaceError Bytes.ByteString)
runWorkspaceGitInput root limit environment args input
  | Bytes.length input > 16777216 || any (\(key, _) -> key `notElem` ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_AUTHOR_DATE", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "GIT_COMMITTER_DATE"]) environment = pure (Left WorkspaceAllocationRefused)
  | otherwise = runGit root limit environment args (Just input)

runGit :: FilePath -> Int -> [(String, String)] -> [String] -> Maybe Bytes.ByteString -> IO (Either WorkspaceError Bytes.ByteString)
runGit root limit environment args input = catch (fromMaybe (Left WorkspaceAllocationRefused) <$> timeout 60000000 work) (\(_ :: IOException) -> pure (Left WorkspaceAllocationRefused))
  where
    work = withFile "/dev/null" WriteMode \sink ->
      withCreateProcess
        ( (proc "git" (["-c", "core.hooksPath=/dev/null", "-c", "protocol.file.allow=always"] <> args))
            { env = Just ([("PATH", "/usr/bin:/bin"), ("HOME", root), ("GIT_CONFIG_NOSYSTEM", "1"), ("GIT_CONFIG_GLOBAL", "/dev/null"), ("GIT_TERMINAL_PROMPT", "0"), ("GIT_NO_REPLACE_OBJECTS", "1"), ("GIT_ATTR_NOSYSTEM", "1")] <> environment),
              close_fds = True,
              std_in = maybe NoStream (const CreatePipe) input,
              std_out = CreatePipe,
              std_err = UseHandle sink
            }
        )
        \incoming output _ process -> case output of
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
            let send = case (incoming, input) of
                  (Just pipe, Just bytes) -> Bytes.hPut pipe bytes `finally` hClose pipe
                  _ -> pure ()
            withAsync send \writer -> do
              bounded <- readBounded 0 []
              case bounded of
                Nothing -> terminateProcess process >> waitForProcess process >> pure (Left WorkspaceAllocationRefused)
                Just bytes -> do
                  wait writer
                  status <- waitForProcess process
                  pure (if status == ExitSuccess then Right bytes else Left WorkspaceAllocationRefused)
