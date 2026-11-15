-- | The host half of a restart-safe attempt, driven with plain shell
-- commands: whatever interrupts it, re-running it never launches twice.
module Shikigami.ProcessLocalSpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, concurrently, withAsync)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.Unique (hashUnique, newUnique)
import Shikigami.Process.Attempt
import Shikigami.Process.Local
import System.Directory (createDirectoryIfMissing, doesFileExist, getTemporaryDirectory, removePathForcibly)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "process attempt"
    [ testCase "a finished attempt is collected, and re-running it collects without relaunching" $ withAttempt \directory -> do
        deadline <- inMinutes 5
        first' <- runAttempt directory deadline parse quietHooks (shell directory "printf '{\"outcome\":\"ran\"}'")
        second' <- runAttempt directory deadline parse quietHooks (shell directory "printf '{\"outcome\":\"again\"}'")
        first' @?= Collected ran
        second' @?= Collected ran
        launches directory >>= (@?= 1),
      testCase "a worker that dies mid-attempt is followed by a reattach, not a second launch" $ withAttempt \directory -> do
        deadline <- inMinutes 5
        let command = shell directory "sleep 3; printf '{\"outcome\":\"ran\"}'"
        -- The first driver is killed after the launch is recorded; its
        -- detached command keeps running.
        withAsync (runAttempt directory deadline parse quietHooks command) \driver -> do
          waitFor (directory </> "launch.json")
          cancel driver
        reattached <- newIORef (0 :: Int)
        let hooks = quietHooks {reattached = \_ -> atomicModifyIORef' reattached (\n -> (n + 1, ()))}
        resumed <- runAttempt directory deadline parse hooks command
        resumed @?= Collected ran
        readIORef reattached >>= (@?= 1)
        launches directory >>= (@?= 1),
      testCase "a launcher gone without a result is uncertain, and stays uncertain" $ withAttempt \directory -> do
        deadline <- inMinutes 5
        let command = shell directory "exit 3"
        runAttempt directory deadline parse quietHooks command >>= (@?= (GaveUp LauncherGoneWithoutResult :: AttemptResult Value))
        runAttempt directory deadline parse quietHooks command >>= (@?= GaveUp LauncherGoneWithoutResult)
        launches directory >>= (@?= 1),
      testCase "a partial result is unreadable" $ withAttempt \directory -> do
        deadline <- inMinutes 5
        runAttempt directory deadline parse quietHooks (shell directory "printf '{\"outc'") >>= (@?= (GaveUp UnreadableResult :: AttemptResult Value)),
      testCase "an intent without a launch record never launches" $ withAttempt \directory -> do
        deadline <- inMinutes 5
        now <- getCurrentTime
        Aeson.encodeFile (directory </> "intent.json") AttemptIntent {at = now}
        result <- runAttempt directory deadline parse quietHooks (assertFailure "prepared a launch" >> undefined)
        result @?= GaveUp IntentWithoutLaunch,
      testCase "a launcher that cannot be spawned is not launched" $ withAttempt \directory -> do
        deadline <- inMinutes 5
        result <- runAttempt directory deadline parse quietHooks (pure AttemptCommand {program = directory </> "missing", arguments = [], workingDirectory = directory})
        case result of
          NotLaunched _ -> pure ()
          other -> assertFailure ("expected NotLaunched, got " <> show other),
      testCase "two drivers of one attempt launch it once" $ withAttempt \directory -> do
        deadline <- inMinutes 5
        let command = shell directory "sleep 1; printf '{\"outcome\":\"ran\"}'"
        (one, two) <- concurrently (runAttempt directory deadline parse quietHooks command) (runAttempt directory deadline parse quietHooks command)
        one @?= Collected ran
        two @?= Collected ran
        launches directory >>= (@?= 1),
      testCase "a live launcher past its deadline and grace is overrun, and is not killed" $ withAttempt \directory -> do
        deadline <- addUTCTime (negate (reattachGrace + 1)) <$> getCurrentTime
        let command = shell directory "sleep 5; printf '{\"outcome\":\"ran\"}'"
        result <- runAttempt directory deadline parse quietHooks command
        result @?= GaveUp LauncherOverran
        facts <- readAttemptFacts directory deadline parse
        facts.launcher @?= LauncherRunning
    ]

ran :: Value
ran = Object (KeyMap.fromList [("outcome", String "ran")])

parse :: ByteString.ByteString -> Maybe Value
parse bytes = case Aeson.decodeStrict bytes of
  Just value@(Object fields) | KeyMap.member "outcome" fields -> Just value
  _ -> Nothing

-- | A shell command that counts its launches beside the attempt directory.
shell :: FilePath -> Text -> IO AttemptCommand
shell directory script =
  pure
    AttemptCommand
      { program = "/bin/sh",
        arguments = ["-c", "echo launched >> ../launches; " <> script],
        workingDirectory = directory
      }

launches :: FilePath -> IO Int
launches directory = do
  let counter = directory </> ".." </> "launches"
  exists <- doesFileExist counter
  if exists then length . lines <$> readFile counter else pure 0

waitFor :: FilePath -> IO ()
waitFor path = go (100 :: Int)
  where
    go 0 = assertFailure ("never appeared: " <> path)
    go n = doesFileExist path >>= \found -> if found then pure () else threadDelay 50000 >> go (n - 1)

inMinutes :: Integer -> IO UTCTime
inMinutes minutes = addUTCTime (fromInteger (minutes * 60)) <$> getCurrentTime

withAttempt :: (FilePath -> IO a) -> IO a
withAttempt action = do
  temporary <- getTemporaryDirectory
  unique <- hashUnique <$> newUnique
  let base = temporary </> ("shikigami-attempt-test-" <> show unique)
      directory = base </> "attempt"
  removePathForcibly base
  createDirectoryIfMissing True directory
  result <- action directory
  removePathForcibly base
  assertBool "cleaned" True
  pure result
