module Shikigami.WorkspaceContainedFileSpec (tests) where

import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.MVar
import Control.Exception (bracket)
import Data.ByteString qualified as Bytes
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Shikigami.Workspace.ContainedFile
import System.Directory
import System.FilePath ((</>))
import System.Process (callProcess)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "workspace contained file boundary"
    [ testCase "reads, compares and atomically replaces regular files" $ withFixture \root metadata _ -> do
        Bytes.writeFile (root </> "file") "old"
        withContainedFile
          root
          "file"
          ( \file -> do
              old <- readContainedFile 262144 file
              old @?= Right (Just "old")
              target <- containedTargetIdentity file
              assertBool "resolved parent identity" (either (const False) (not . Text.null) target)
              replaceContainedFile metadata file (Just "old") "new"
          )
          >>= (@?= Right ())
        Bytes.readFile (root </> "file") >>= (@?= "new")
        aliases <- doesFileExist (root </> "FILE")
        if aliases then withContainedFile root "FILE" (readContainedFile 10) >>= (@?= Left FilePathRefused) else pure ()
        withContainedFile root "created" (\file -> replaceContainedFile metadata file Nothing "created") >>= (@?= Right ())
        Bytes.readFile (root </> "created") >>= (@?= "created"),
      testCase "rejects traversal, Git metadata, symlinks and hardlinks" $ withFixture \root _ outside -> do
        Bytes.writeFile (outside </> "secret") "PRIVATE_OUTSIDE"
        createFileLink (outside </> "secret") (root </> "link")
        createDirectoryLink outside (root </> "directory-link")
        callProcess "ln" [outside </> "secret", root </> "hardlink"]
        mapM_ (\path -> withContainedFile root path (\_ -> assertFailure "unsafe target opened" >> pure (Right ())) >>= (@?= Left FilePathRefused)) ["../outside/secret", "/etc/passwd", ".git/config", "x/.Git/config", "link", "directory-link/secret", "hardlink", "日本/file"]
        Bytes.readFile (outside </> "secret") >>= (@?= "PRIVATE_OUTSIDE"),
      testCase "refuses substituted leaf and parent after target resolution" $ withFixture \root metadata outside -> do
        Bytes.writeFile (outside </> "file") "PRIVATE_OUTSIDE"
        Bytes.writeFile (root </> "file") "old"
        withContainedFile
          root
          "file"
          ( \file -> do
              removeFile (root </> "file")
              createFileLink (outside </> "file") (root </> "file")
              replaceContainedFile metadata file (Just "old") "replacement"
          )
          >>= (@?= Left FileContentConflict)
        createDirectory (root </> "nested")
        Bytes.writeFile (root </> "nested" </> "file") "old"
        withContainedFile
          root
          "nested/file"
          ( \file -> do
              renameDirectory (root </> "nested") (root </> "retained")
              createDirectoryLink outside (root </> "nested")
              replaceContainedFile metadata file (Just "old") "replacement"
          )
          >>= (@?= Left FileContentConflict)
        Bytes.readFile (outside </> "file") >>= (@?= "PRIVATE_OUTSIDE")
        Bytes.readFile (root </> "retained" </> "file") >>= (@?= "old"),
      testCase "rechecks same-inode bytes and bounds reads without blocking on FIFOs" $ withFixture \root metadata _ -> do
        Bytes.writeFile (root </> "file") "old"
        withContainedFile
          root
          "file"
          ( \file -> do
              Bytes.writeFile (root </> "file") "bad"
              replaceContainedFile metadata file (Just "old") "replacement"
          )
          >>= (@?= Left FileContentConflict)
        withContainedFile root "file" (readContainedFile 2) >>= (@?= Left FileTooLarge)
        callProcess "mkfifo" [root </> "fifo"]
        timeout 1000000 (withContainedFile root "fifo" (readContainedFile 10)) >>= (@?= Just (Left FilePathRefused)),
      testCase "independent clients share a nonblocking lock released on interruption" $ withFixture \_ metadata _ -> do
        reached <- newEmptyMVar
        block <- newEmptyMVar
        owner <- async (withWorkspaceLock metadata (putMVar reached () >> takeMVar block >> pure (Right ())))
        takeMVar reached
        withWorkspaceLock metadata (assertFailure "concurrent owner entered" >> pure (Right ())) >>= (@?= Left FileBusy)
        cancel owner
        withWorkspaceLock metadata (pure (Right ())) >>= (@?= Right ())
    ]

withFixture :: (FilePath -> FilePath -> FilePath -> IO a) -> IO a
withFixture use = bracket create removeDirectoryRecursive \temporary -> do
  let root = temporary </> "files"
      metadata = temporary </> "metadata"
      outside = temporary </> "outside"
  mapM_ createDirectory [root, metadata, outside]
  ensurePrivateDirectory metadata >>= (@?= Right ())
  use root metadata outside
  where
    create = do
      parent <- getTemporaryDirectory >>= canonicalizePath
      nonce <- UUID.toString <$> UUID.nextRandom
      let directory = parent </> ("shikigami-contained-" <> nonce)
      createDirectory directory
      pure directory
