module Shikigami.DirectorySpec (tests) where

import Control.Exception (bracket)
import Control.Lens ((&), (.~))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (secondsToNominalDiffTime)
import Shikigami.Activity.Coordinate
import Shikigami.Agent.DeclarationValue
import Shikigami.Directory
import Shikigami.Log qualified as Log
import Shikigami.Trigger.Schedule (parseCron)
import System.Directory (getTemporaryDirectory, removeFile, renameFile)
import System.IO (hClose, openBinaryTempFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "principal directory"
    [ testCase "disabled mode preserves compatibility" $
        consultLifecycle disabledDirectoryHandle (Just (declarationCoordinate "agent_missing")) "missing"
          >>= (@?= AllowRun Nothing),
      testCase "disabled mode has an explicit immutable snapshot" do
        readDirectorySnapshot disabledDirectoryHandle >>= \case
          DirectoryDisabledSnapshot {} -> pure ()
          other -> assertFailure ("expected disabled snapshot, got " <> show other),
      testCase "configured mode without a valid snapshot fails closed" do
        directoryHandle <- newDirectoryHandle (pure (Left "meibo unavailable"))
        consultLifecycle directoryHandle Nothing "heartbeat"
          >>= (@?= DirectoryUnavailable "directory has no valid snapshot")
        readDirectorySnapshot directoryHandle >>= \case
          DirectoryUnavailableSnapshot {source = DirectoryFileSource} -> pure ()
          other -> assertFailure ("expected file-backed unavailable snapshot, got " <> show other)
        refreshDirectory directoryHandle >>= (@?= Left "meibo unavailable")
        consultLifecycle directoryHandle Nothing "heartbeat"
          >>= (@?= DirectoryUnavailable "meibo unavailable"),
      testCase "configured startup refuses an unavailable initial snapshot" do
        temporaryDirectory <- getTemporaryDirectory
        (missingPath, fileHandle) <- openBinaryTempFile temporaryDirectory "shikigami-directory-missing.json"
        hClose fileHandle
        removeFile missingPath
        started <- startDirectory Log.silentLogger (DirectoryFile missingPath (secondsToNominalDiffTime 5))
        case started of
          Left problem -> assertBool ("expected read failure, got " <> show problem) ("could not read directory file" `Text.isInfixOf` problem)
          Right _ -> assertFailure "configured startup unexpectedly accepted a missing directory file",
      testCase "active principal is admitted and extra Meibo fields are ignored" $
        withDirectoryHandle activeDirectory do
          \directoryHandle ->
            consultLifecycle directoryHandle (Just (declarationCoordinate heartbeatId)) "wrong-handle"
              >>= (@?= AllowRun (Just heartbeat)),
      testCase "handle fallback is case-insensitive and trimmed" $
        withDirectoryHandle activeDirectory do
          \directoryHandle ->
            consultLifecycle directoryHandle Nothing "  HEARTBEAT  "
              >>= (@?= AllowRun (Just heartbeat)),
      testCase "an explicit principal id never falls back to the handle" $
        withDirectoryHandle activeDirectory do
          \directoryHandle ->
            consultLifecycle directoryHandle (Just (declarationCoordinate "agent_unknown")) "heartbeat"
              >>= (@?= UnknownPrincipal "agent_unknown"),
      testCase "paused and deactivated principals are skipped" $
        withDirectoryHandle lifecycleDirectory do
          \directoryHandle -> do
            consultLifecycle directoryHandle (Just (declarationCoordinate heartbeatId)) "heartbeat"
              >>= (@?= SkipRun heartbeatPaused "principal lifecycle is paused")
            consultLifecycle directoryHandle (Just (declarationCoordinate archiveId)) "archive"
              >>= (@?= SkipRun archive "principal lifecycle is deactivated"),
      testCase "unknown handle is rejected in configured mode" $
        withDirectoryHandle activeDirectory do
          \directoryHandle ->
            consultLifecycle directoryHandle Nothing "missing"
              >>= (@?= UnknownPrincipal "missing"),
      testCase "duplicate principal ids and normalized handles reject the whole snapshot" do
        assertRefreshFails duplicateIdDirectory "duplicate principal id"
        assertRefreshFails duplicateHandleDirectory "duplicate normalized handle",
      testCase "invalid principal ids and empty handles reject the whole snapshot" do
        assertRefreshFails invalidIdDirectory "principal id must begin with agent_"
        assertRefreshFails emptyHandleDirectory "principal handle must not be empty",
      testCase "invalid refresh retains the exact last valid snapshot" $
        withDirectoryFile activeDirectory do
          \filePath -> do
            directoryHandle <- newDirectoryHandle (fileDirectorySource filePath)
            refreshDirectory directoryHandle >>= (@?= Right ())
            beforeFailure <- readDirectorySnapshot directoryHandle
            BS.writeFile filePath duplicateHandleDirectory
            refreshDirectory directoryHandle >>= assertLeftContaining "duplicate normalized handle"
            readDirectorySnapshot directoryHandle >>= (@?= beforeFailure)
            consultLifecycle directoryHandle (Just (declarationCoordinate heartbeatId)) "heartbeat"
              >>= (@?= AllowRun (Just heartbeat)),
      testCase "identical refreshes preserve the semantic snapshot version" $
        withDirectoryFile activeDirectory do
          \filePath -> do
            directoryHandle <- newDirectoryHandle (fileDirectorySource filePath)
            refreshDirectory directoryHandle >>= (@?= Right ())
            first <- readDirectorySnapshot directoryHandle
            refreshDirectory directoryHandle >>= (@?= Right ())
            readDirectorySnapshot directoryHandle >>= (@?= first),
      testCase "one live handle observes pause and reactivation after file refresh" $
        withDirectoryFile activeDirectory do
          \filePath -> do
            directoryHandle <- newDirectoryHandle (fileDirectorySource filePath)
            refreshDirectory directoryHandle >>= (@?= Right ())
            consultLifecycle directoryHandle (Just (declarationCoordinate heartbeatId)) "heartbeat"
              >>= (@?= AllowRun (Just heartbeat))
            replaceFileAtomically filePath pausedDirectory
            refreshDirectory directoryHandle >>= (@?= Right ())
            consultLifecycle directoryHandle (Just (declarationCoordinate heartbeatId)) "heartbeat"
              >>= (@?= SkipRun heartbeatPaused "principal lifecycle is paused")
            replaceFileAtomically filePath activeDirectory
            refreshDirectory directoryHandle >>= (@?= Right ())
            consultLifecycle directoryHandle (Just (declarationCoordinate heartbeatId)) "heartbeat"
              >>= (@?= AllowRun (Just heartbeat)),
      testCase "inspection order is deterministic by normalized handle" $
        withDirectoryHandle lifecycleDirectory do
          \directoryHandle ->
            directoryPrincipals directoryHandle >>= (@?= [archive, heartbeatPaused])
    ]

heartbeatId :: Text
heartbeatId = "agent_01h000000000000000heartbeat"

archiveId :: Text
archiveId = "agent_01h0000000000000000archive"

heartbeat :: PrincipalRecord
heartbeat = PrincipalRecord {principalId = declarationCoordinate (heartbeatId), handle = declarationCoordinate ("heartbeat"), lifecycle = Active}

heartbeatPaused :: PrincipalRecord
heartbeatPaused = (heartbeat & #lifecycle .~ (Paused))

archive :: PrincipalRecord
archive = PrincipalRecord {principalId = declarationCoordinate (archiveId), handle = declarationCoordinate ("archive"), lifecycle = Deactivated}

activeDirectory :: ByteString
activeDirectory =
  """
  [{"principal_id":"agent_01h000000000000000heartbeat","handle":"heartbeat","lifecycle":"active","display_name":"Heartbeat Agent"}]
  """

lifecycleDirectory :: ByteString
lifecycleDirectory =
  """
  [
    {"principal_id":"agent_01h000000000000000heartbeat","handle":"heartbeat","lifecycle":"paused"},
    {"principal_id":"agent_01h0000000000000000archive","handle":"archive","lifecycle":"deactivated"}
  ]
  """

pausedDirectory :: ByteString
pausedDirectory =
  """
  [{"principal_id":"agent_01h000000000000000heartbeat","handle":"heartbeat","lifecycle":"paused"}]
  """

duplicateIdDirectory :: ByteString
duplicateIdDirectory =
  """
  [
    {"principal_id":"agent_duplicate","handle":"first","lifecycle":"active"},
    {"principal_id":"agent_duplicate","handle":"second","lifecycle":"active"}
  ]
  """

duplicateHandleDirectory :: ByteString
duplicateHandleDirectory =
  """
  [
    {"principal_id":"agent_first","handle":"Heartbeat","lifecycle":"active"},
    {"principal_id":"agent_second","handle":" heartbeat ","lifecycle":"paused"}
  ]
  """

invalidIdDirectory :: ByteString
invalidIdDirectory =
  """
  [{"principal_id":"person_not_an_agent","handle":"heartbeat","lifecycle":"active"}]
  """

emptyHandleDirectory :: ByteString
emptyHandleDirectory =
  """
  [{"principal_id":"agent_empty","handle":"   ","lifecycle":"active"}]
  """

withDirectoryHandle :: ByteString -> (DirectoryHandle -> IO a) -> IO a
withDirectoryHandle contents action =
  withDirectoryFile contents \filePath -> do
    directoryHandle <- newDirectoryHandle (fileDirectorySource filePath)
    refreshDirectory directoryHandle >>= \case
      Left problem -> assertFailure ("expected valid directory: " <> show problem)
      Right () -> action directoryHandle

withDirectoryFile :: ByteString -> (FilePath -> IO a) -> IO a
withDirectoryFile contents =
  bracket acquire removeFile
  where
    acquire = do
      temporaryDirectory <- getTemporaryDirectory
      (filePath, fileHandle) <- openBinaryTempFile temporaryDirectory "shikigami-directory.json"
      BS.hPut fileHandle contents
      hClose fileHandle
      pure filePath

assertRefreshFails :: ByteString -> Text -> IO ()
assertRefreshFails contents expected =
  withDirectoryFile contents \filePath -> do
    directoryHandle <- newDirectoryHandle (fileDirectorySource filePath)
    refreshDirectory directoryHandle >>= assertLeftContaining expected

assertLeftContaining :: Text -> Either Text a -> IO ()
assertLeftContaining expected = \case
  Left problem -> assertBool ("expected " <> show expected <> " in " <> show problem) (expected `Text.isInfixOf` problem)
  Right _ -> assertFailure ("expected failure containing " <> show expected)

replaceFileAtomically :: FilePath -> ByteString -> IO ()
replaceFileAtomically filePath contents = do
  let candidate = filePath <> ".next"
  BS.writeFile candidate contents
  renameFile candidate filePath
