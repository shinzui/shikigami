module Shikigami.WorkspaceGitObjectsSpec (tests) where

import Control.Exception (bracket)
import Data.ByteString qualified as Bytes
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (UTCTime (..), fromGregorian)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Workspace.ContainedFile (ensurePrivateDirectory)
import Shikigami.Workspace.Git (runWorkspaceGit)
import Shikigami.Workspace.GitObjects
import Shikigami.Workspace.Types (WorkspaceError)
import System.Directory (createDirectory, doesFileExist, getTemporaryDirectory, removeFile, removePathForcibly)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "workspace trusted Git objects"
    [ testCase "exact bytes and executable intent form an isolated tree without filters" $ fixture \root metadata parent -> do
        marker <- armHelpers root metadata
        blob <- right =<< storeBlob metadata "new dependency\r\n"
        attributes <- right =<< storeBlob metadata "* filter=hostile diff=hostile\n"
        tree <- right =<< storeTree metadata [GitEntry "dependency.txt" "100755" blob, GitEntry ".gitattributes" "100644" attributes]
        result <- right =<< storeCommit metadata parent tree author now (OperationId "upgrade") "Upgrade dependency"
        git root ["--git-dir=" <> metadata, "show", Text.unpack result <> ":dependency.txt"] >>= (@?= "new dependency\r\n")
        entries <- git root ["--git-dir=" <> metadata, "ls-tree", Text.unpack tree]
        assertBool "mode retained" ("100755 blob " `Bytes.isInfixOf` entries)
        changedPaths metadata parent result >>= (@?= Right [".gitattributes", "dependency.txt"])
        patch <- right =<< objectDiff metadata parent result
        assertBool "bounded object diff" ("new dependency" `Bytes.isInfixOf` patch)
        doesFileExist marker >>= (@?= False)
        readHead metadata >>= (@?= Right parent),
      testCase "retained commit publishes once and recovers acknowledgement loss" $ fixture \root metadata parent -> do
        marker <- armHelpers root metadata
        blob <- right =<< storeBlob metadata "upgrade\n"
        tree <- right =<< storeTree metadata [GitEntry "dependency.txt" "100644" blob]
        result <- right =<< storeCommit metadata parent tree author now (OperationId "accepted-operation") "Upgrade"
        storeCommit metadata parent tree author now (OperationId "accepted-operation") "Upgrade" >>= (@?= Right result)
        publishCommit metadata parent result >>= (@?= Right ())
        publishCommit metadata parent result >>= (@?= Right ())
        readHead metadata >>= (@?= Right result)
        git root ["--git-dir=" <> metadata, "rev-list", "--count", "HEAD"] >>= (@?= "2\n")
        doesFileExist marker >>= (@?= False),
      testCase "a competing parent cannot overwrite a published commit" $ fixture \_ metadata parent -> do
        blob <- right =<< storeBlob metadata "upgrade\n"
        tree <- right =<< storeTree metadata [GitEntry "dependency.txt" "100644" blob]
        one <- right =<< storeCommit metadata parent tree author now (OperationId "one") "Upgrade"
        two <- right =<< storeCommit metadata parent tree author now (OperationId "two") "Upgrade"
        assertBool "operation identity retained" (one /= two)
        publishCommit metadata parent one >>= (@?= Right ())
        publishCommit metadata parent two >>= assertLeft
        readHead metadata >>= (@?= Right one),
      testCase "publication refuses an unretained additional parent" $ fixture \root metadata parent -> do
        blob <- right =<< storeBlob metadata "upgrade\n"
        tree <- right =<< storeTree metadata [GitEntry "dependency.txt" "100644" blob]
        other <- right =<< storeCommit metadata parent tree author now (OperationId "other") "Other"
        merged <- Text.strip . Encoding.decodeUtf8 <$> git root ["--git-dir=" <> metadata, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit-tree", Text.unpack tree, "-p", Text.unpack parent, "-p", Text.unpack other, "-m", "Unexpected merge"]
        publishCommit metadata parent merged >>= assertLeft
        readHead metadata >>= (@?= Right parent),
      testCase "malicious tree names, aliases, modes and absent objects refuse" $ fixture \_ metadata _ -> do
        blob <- right =<< storeBlob metadata "safe"
        mapM_
          (\entry -> storeTree metadata [entry] >>= assertLeft)
          [GitEntry "../escape" "100644" blob, GitEntry ".Git" "100644" blob, GitEntry "dir/file" "100644" blob, GitEntry "name\n" "100644" blob, GitEntry "é" "100644" blob, GitEntry "link" "120000" blob, GitEntry "missing" "100644" (Text.replicate 40 "0")]
        storeTree metadata [GitEntry "A" "100644" blob, GitEntry "a" "100644" blob] >>= assertLeft
        storeTree metadata [GitEntry "wrong-type" "040000" blob] >>= assertLeft,
      testCase "oversized blobs and diffs return a bounded refusal" $ fixture \_ metadata parent -> do
        storeBlob metadata (Bytes.replicate 262145 120) >>= assertLeft
        blob <- right =<< storeBlob metadata (Bytes.replicate 262144 120)
        tree <- right =<< storeTree metadata [GitEntry "dependency.txt" "100644" blob]
        objectDiff metadata parent tree >>= assertLeft,
      testCase "exposed metadata refuses without permission repair" $ fixture \_ metadata _ -> do
        setFileMode metadata 0o755
        storeBlob metadata "private" >>= assertLeft
    ]

fixture :: (FilePath -> FilePath -> Text.Text -> IO a) -> IO a
fixture use = do
  temporary <- getTemporaryDirectory
  key <- UUID.toString <$> UUID.nextRandom
  let root = temporary </> ("shikigami-git-objects-" <> key)
      metadata = root </> "metadata"
  bracket (createDirectory root >> pure root) removePathForcibly \_ -> do
    _ <- git root ["init", "--bare", metadata]
    ensurePrivateDirectory metadata >>= (@?= Right ())
    -- Establish the initial commit using the same object-only transport. The
    -- initial root is fixture setup, never a provider-created replacement base.
    blob <- right =<< storeBlob metadata "old dependency\n"
    tree <- right =<< storeTree metadata [GitEntry "dependency.txt" "100644" blob]
    parent <- Text.strip . Encoding.decodeUtf8 <$> git root ["--git-dir=" <> metadata, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit-tree", "-m", "Base", Text.unpack tree]
    _ <- git root ["--git-dir=" <> metadata, "update-ref", "--no-deref", "HEAD", Text.unpack parent]
    use root metadata parent

armHelpers :: FilePath -> FilePath -> IO FilePath
armHelpers root metadata = do
  let marker = root </> "helper-executed"
      hook = metadata </> "hooks/reference-transaction"
  writeFile hook ("#!/bin/sh\ntouch '" <> marker <> "'\n")
  setFileMode hook 0o700
  _ <- git root ["--git-dir=" <> metadata, "config", "filter.hostile.clean", "touch '" <> marker <> "'"]
  _ <- git root ["--git-dir=" <> metadata, "config", "diff.hostile.command", "touch '" <> marker <> "'"]
  _ <- git root ["--git-dir=" <> metadata, "config", "diff.external", "touch '" <> marker <> "'"]
  parent <- right =<< readHead metadata
  _ <- git root ["--git-dir=" <> metadata, "-c", "core.hooksPath=" <> metadata </> "hooks", "update-ref", "refs/test/hook-control", Text.unpack parent]
  doesFileExist marker >>= (@?= True)
  removeFile marker
  pure marker

git :: FilePath -> [String] -> IO Bytes.ByteString
git root arguments = right =<< runWorkspaceGit root 1048576 arguments

right :: Either WorkspaceError a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

assertLeft :: Either a b -> Assertion
assertLeft = either (const (pure ())) (const (assertFailure "expected refusal"))

author :: GitAuthor
author = GitAuthor "Shikigami Fixture" "fixture@example.invalid"

now :: UTCTime
now = UTCTime (fromGregorian 2026 10 30) 0
