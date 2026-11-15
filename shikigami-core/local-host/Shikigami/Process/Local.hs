-- | The host half of a restart-safe attempt ("Shikigami.Process.Attempt").
--
-- 'runAttempt' reads the facts of an attempt directory, asks
-- 'recoverAttempt' what they mean, and then collects the result, reattaches
-- to the live launcher and waits for it, gives up as uncertain, or launches
-- the command fresh. A fresh launch first claims the attempt by linking a
-- complete intent file into place, which succeeds for exactly one driver, and
-- runs the command detached in its own session so that neither an interrupt
-- nor the death of the worker reaches it. The command must write its result
-- to its standard output, which goes to the attempt's result file, and exit.
--
-- The launched command is a parameter: the coding-agent runner is one caller,
-- and a test drives it with a plain shell command.
module Shikigami.Process.Local
  ( AttemptCommand (..),
    AttemptHooks (..),
    quietHooks,
    AttemptFiles (..),
    attemptFiles,
    runAttempt,
    readAttemptFacts,
    processStart,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, throwIO, try)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.Unique (hashUnique, newUnique)
import Shikigami.Process.Attempt
import System.Directory (doesFileExist, removeFile, renameFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hClose, openFile)
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Files (createLink)
import System.Posix.Process (getProcessID)
import System.Process

-- | What a fresh launch runs. It is prepared only when the attempt really
-- launches, so a reattach or a collection writes nothing.
data AttemptCommand = AttemptCommand
  { program :: !FilePath,
    arguments :: ![Text],
    workingDirectory :: !FilePath
  }
  deriving stock (Eq, Show)

-- | Observations of what the attempt did, for the action record.
data AttemptHooks = AttemptHooks
  { launched :: !(LaunchRecord -> IO ()),
    reattached :: !(LaunchRecord -> IO ())
  }

quietHooks :: AttemptHooks
quietHooks = AttemptHooks {launched = \_ -> pure (), reattached = \_ -> pure ()}

-- | The files of an attempt directory.
data AttemptFiles = AttemptFiles
  { intent :: !FilePath,
    launch :: !FilePath,
    result :: !FilePath,
    stderr :: !FilePath
  }
  deriving stock (Eq, Show)

attemptFiles :: FilePath -> AttemptFiles
attemptFiles directory =
  AttemptFiles
    { intent = directory </> "intent.json",
      launch = directory </> "launch.json",
      result = directory </> "envelope.json",
      stderr = directory </> "stderr.log"
    }

-- | Launch, reattach, collect or give up, restart-safely. Re-executing it
-- after any interruption never starts the command a second time.
runAttempt ::
  -- | The attempt directory, which must exist.
  FilePath ->
  -- | The attempt's absolute deadline; a live launcher is waited for until
  -- it plus 'reattachGrace'.
  UTCTime ->
  -- | Parses a complete result file; 'Nothing' means partial.
  (ByteString.ByteString -> Maybe r) ->
  AttemptHooks ->
  IO AttemptCommand ->
  IO (AttemptResult r)
runAttempt directory deadline parse hooks prepare = decide (3 :: Int)
  where
    paths = attemptFiles directory
    facts = readAttemptFacts directory deadline parse
    decide retries = do
      known <- facts
      case recoverAttempt known of
        Collect value -> pure (Collected value)
        GiveUp reason -> pure (GaveUp reason)
        Reattach record -> do
          hooks.reattached record
          waitWhileLive record
          concluded
        LaunchFresh -> do
          now <- getCurrentTime
          claimed <- claim AttemptIntent {at = now}
          if claimed
            then launchFresh
            else do
              -- Another driver claimed the attempt first: give it time to
              -- record its launch, then decide from what it wrote.
              awaitLaunchRecord (10 :: Int)
              if retries > 0 then decide (retries - 1) else pure (GaveUp IntentWithoutLaunch)
    -- Link a complete intent file into place; exactly one driver succeeds.
    claim intentValue = do
      self <- getProcessID
      unique <- hashUnique <$> newUnique
      let staged = paths.intent <> "." <> show self <> "-" <> show unique <> ".tmp"
      LazyByteString.writeFile staged (Aeson.encode intentValue)
      linked <- try (createLink staged paths.intent)
      removeFile staged
      case linked of
        Right () -> pure True
        Left problem
          | isAlreadyExistsError problem -> pure False
          | otherwise -> throwIO problem
    awaitLaunchRecord remaining = do
      recorded <- doesFileExist paths.launch
      if recorded || remaining <= 0 then pure () else threadDelay 1000000 >> awaitLaunchRecord (remaining - 1)
    launchFresh = do
      AttemptCommand {program, arguments, workingDirectory} <- prepare
      out <- openFile paths.result WriteMode
      err <- openFile paths.stderr WriteMode
      spawned <-
        try
          ( createProcess
              (proc program (Text.unpack <$> arguments))
                { cwd = Just workingDirectory,
                  std_in = NoStream,
                  std_out = UseHandle out,
                  std_err = UseHandle err,
                  new_session = True,
                  close_fds = True
                }
          )
      case spawned of
        Left (problem :: IOException) -> do
          hClose out >> hClose err
          writeFile paths.stderr (show problem)
          pure (NotLaunched (Text.pack (show problem)))
        Right (_, _, _, handle) ->
          getPid handle >>= \case
            Nothing -> pure (NotLaunched "the launcher exited before its pid was read")
            Just pidValue -> do
              let pid = fromIntegral pidValue
              started <- processStart pid
              let record = LaunchRecord {pid, startedAt = fromMaybe "" started}
              writeAtomically paths.launch (Aeson.encode record)
              hooks.launched record
              waitForChild handle
              concluded
    -- Our own child: reap it when it exits, or stop waiting past the grace.
    waitForChild handle = do
      exited <- getProcessExitCode handle
      now <- getCurrentTime
      case exited of
        Just _ -> pure ()
        Nothing
          | now > addUTCTime reattachGrace deadline -> pure ()
          | otherwise -> threadDelay 500000 >> waitForChild handle
    waitWhileLive LaunchRecord {pid, startedAt} = do
      alive <- isLive pid startedAt
      now <- getCurrentTime
      if alive && now <= addUTCTime reattachGrace deadline then threadDelay 1000000 >> waitWhileLive LaunchRecord {pid, startedAt} else pure ()
    -- After waiting: the result if it is complete, otherwise why not.
    concluded = do
      known <- facts
      pure case (known.envelope, known.launcher) of
        (Envelope value, _) -> Collected value
        (_, LauncherRunning) -> GaveUp LauncherOverran
        (PartialEnvelope, _) -> GaveUp UnreadableResult
        (NoEnvelope, _) -> GaveUp LauncherGoneWithoutResult

-- | The facts of an attempt directory, for 'recoverAttempt'.
readAttemptFacts :: FilePath -> UTCTime -> (ByteString.ByteString -> Maybe r) -> IO (AttemptFacts r)
readAttemptFacts directory deadline parse = do
  let paths = attemptFiles directory
  intent <- readJson paths.intent
  launch <- readJson paths.launch
  envelope <- do
    exists <- doesFileExist paths.result
    if not exists
      then pure NoEnvelope
      else do
        bytes <- ByteString.readFile paths.result
        pure
          if ByteString.null bytes
            then NoEnvelope
            else maybe PartialEnvelope Envelope (parse bytes)
  launcher <- case launch of
    Nothing -> pure LauncherAbsent
    Just LaunchRecord {pid, startedAt} -> (\alive -> if alive then LauncherRunning else LauncherGone) <$> isLive pid startedAt
  now <- getCurrentTime
  pure AttemptFacts {intent, launch, envelope, launcher, now, deadline}

-- | A pid is the recorded launcher only while it runs and its start time
-- still matches; a zombie has already exited.
isLive :: Int -> Text -> IO Bool
isLive pid startedAt = do
  current <- processStart pid
  pure (maybe False (\started -> Text.null startedAt || started == startedAt) current)

-- | The start time of a running (not zombie) process.
processStart :: Int -> IO (Maybe Text)
processStart pid = do
  result <- try @IOException (readProcessWithExitCode "ps" ["-o", "stat=", "-o", "lstart=", "-p", show pid] "")
  pure case result of
    Right (ExitSuccess, out, _) -> case Text.words (Text.strip (Text.pack out)) of
      state : started | not (null started), not ("Z" `Text.isPrefixOf` state) -> Just (Text.unwords started)
      _ -> Nothing
    _ -> Nothing

readJson :: (Aeson.FromJSON a) => FilePath -> IO (Maybe a)
readJson path = do
  exists <- doesFileExist path
  if exists then Aeson.decodeStrict <$> ByteString.readFile path else pure Nothing

writeAtomically :: FilePath -> LazyByteString.ByteString -> IO ()
writeAtomically path bytes = do
  LazyByteString.writeFile (path <> ".tmp") bytes
  renameFile (path <> ".tmp") path
