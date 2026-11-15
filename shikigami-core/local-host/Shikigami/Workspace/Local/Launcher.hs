-- | The host process launcher of the local-operator tier.
--
-- A command runs in its own process group with a cleared environment (the
-- fixed minimal set plus the rule's @inherit@ names) and no standard input.
-- Both output streams are drained concurrently; the first @outputLimit@
-- bytes of each are kept and the rest counted. At the deadline the whole
-- group receives @SIGTERM@ and, five seconds later, @SIGKILL@, so a detached
-- descendant cannot outlive the command.
module Shikigami.Workspace.Local.Launcher (hostProcessLauncher) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, race, wait)
import Control.Exception (IOException, SomeException, try)
import Control.Monad (void)
import Data.ByteString qualified as ByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (mapMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Numeric.Natural (Natural)
import Shikigami.Trust.LocalOperator.Approvals (launchDeadlineSeconds, outputLimitBytes, programPathText)
import Shikigami.Workspace.Launch
import System.Environment (getEnvironment)
import System.IO (Handle, hClose)
import System.Posix.Signals (sigKILL, sigTERM, signalProcessGroup)
import System.Process

hostProcessLauncher :: ProcessLauncher
hostProcessLauncher = ProcessLauncher {launch = launchOnHost}

-- | Names every command receives from the operator's environment.
baseEnvironment :: [String]
baseEnvironment = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"]

launchOnHost :: LaunchRequest -> IO (Either LaunchRefusal LaunchResult)
launchOnHost LaunchRequest {program, arguments, directory, inherit, deadline, outputLimit} = do
  ambient <- getEnvironment
  let wanted = baseEnvironment <> (Text.unpack <$> inherit)
      environment = mapMaybe (\name -> (name,) <$> lookup name ambient) wanted
      spec =
        (proc (Text.unpack (programPathText program)) (Text.unpack <$> arguments))
          { cwd = Just (worktreeRootPath directory),
            env = Just environment,
            std_in = NoStream,
            std_out = CreatePipe,
            std_err = CreatePipe,
            create_group = True,
            close_fds = True
          }
      limit = fromIntegral (outputLimitBytes outputLimit)
  started <- getCurrentTime
  spawned <- try (createProcess spec)
  case spawned of
    Left (problem :: IOException) -> pure (Left (LaunchFailed (Text.pack (show problem))))
    Right (_, Just out, Just err, handle) -> do
      group <- getPid handle
      -- Drain while the process runs, or a full pipe would block it.
      outs <- async (drain limit out)
      errs <- async (drain limit err)
      let seconds = fromIntegral (launchDeadlineSeconds deadline) :: Int
      outcome <-
        race (threadDelay (seconds * 1000000)) (waitForProcess handle) >>= \case
          Right code -> pure (Exited code)
          Left () -> do
            terminateGroup group
            race (threadDelay 5000000) (waitForProcess handle) >>= \case
              Right _ -> pure ()
              Left () -> killGroup group >> void (waitForProcess handle)
            pure DeadlineExpired
      stdout <- wait outs
      stderr <- wait errs
      finished <- getCurrentTime
      pure (Right LaunchResult {outcome, stdout, stderr, elapsedMs = round (1000 * diffUTCTime finished started)})
    Right (_, _, _, handle) -> do
      terminateProcess handle
      pure (Left (LaunchFailed "the process started without output pipes"))
  where
    terminateGroup = maybe (pure ()) (\pid -> void (try @SomeException (signalProcessGroup sigTERM pid)))
    killGroup = maybe (pure ()) (\pid -> void (try @SomeException (signalProcessGroup sigKILL pid)))

-- | Read a stream to its end, keeping the first @limit@ bytes.
drain :: Int -> Handle -> IO CapturedOutput
drain limit handle = do
  kept <- newIORef ByteString.empty
  dropped <- newIORef (0 :: Natural)
  let loop = do
        chunk <- try (ByteString.hGetSome handle 65536)
        case chunk of
          Left (_ :: IOException) -> pure ()
          Right bytes
            | ByteString.null bytes -> pure ()
            | otherwise -> do
                overflow <- atomicModifyIORef' kept \current ->
                  let room = max 0 (limit - ByteString.length current)
                      (taken, rest) = ByteString.splitAt room bytes
                   in (current <> taken, ByteString.length rest)
                atomicModifyIORef' dropped (\n -> (n + fromIntegral overflow, ()))
                loop
  loop
  void (try @IOException (hClose handle))
  CapturedOutput <$> (Text.Encoding.decodeUtf8Lenient <$> readIORef kept) <*> readIORef dropped
