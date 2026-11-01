{-# LANGUAGE DataKinds #-}

module Shikigami.WorkspaceGitObjectsSpec (tests) where

import Control.Exception (bracket)
import Data.ByteString qualified as Bytes
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (UTCTime (..), fromGregorian)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Fixture.ExecutionIdentity (fixtureOperationId)
import Shikigami.Workspace.ContainedFile (ensurePrivateDirectory)
import Shikigami.Workspace.Git (runWorkspaceGit, runWorkspaceGitInput)
import Shikigami.Workspace.GitObjects
import Shikigami.Workspace.Types (WorkspaceError)
import Shikigami.Workspace.Value
import System.Directory (createDirectory, doesFileExist, getTemporaryDirectory, removeFile, removePathForcibly)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "workspace trusted Git objects"
    [ testCase "exact reads preserve bytes and reject expressions and wrong types" $ fixture \_ metadata parent -> do
        (tree, parents) <- right =<< readCommit metadata parent
        parents @?= []
        entries <- right =<< readFlatTree metadata tree
        map (workspaceCoordinateText . (.name)) entries @?= ["dependency.txt"]
        let [entry] = entries
        readBlob metadata 1024 entry.objectId >>= (@?= Right "old dependency\n")
        readCommit metadata (workspaceCoordinate (workspaceCoordinateText parent <> "^{commit}")) >>= assertLeft
        readCommit metadata tree >>= assertLeft
        readFlatTree metadata parent >>= assertLeft
        readBlob metadata 1024 tree >>= assertLeft
        readBlob metadata 2 entry.objectId >>= assertLeft,
      testCase "immutable artifacts remain readable after source HEAD advances" $ fixture \_ metadata parent -> do
        blob <- right =<< storeBlob metadata "first\n"
        tree <- right =<< storeFlatTree metadata [GitEntry (workspaceCoordinate "dependency.txt") GitRegular blob]
        first <- right =<< storeCommit metadata parent tree author now (fixtureOperationId "first") (workspaceCoordinate "First")
        publishCommit metadata parent first >>= (@?= Right ())
        second <- right =<< storeCommit metadata first tree author now (fixtureOperationId "second") (workspaceCoordinate "Second")
        publishCommit metadata first second >>= (@?= Right ())
        readCommit metadata first >>= (@?= Right (tree, [parent]))
        readHead metadata >>= (@?= Right second),
      testCase "untrusted existing trees refuse symlinks and case aliases" $ fixture \root metadata _ -> do
        blob <- right =<< storeBlob metadata "outside"
        symlink <- rawTree root metadata ("120000 blob " <> workspaceCoordinateText blob <> "\tlink\0")
        aliases <- rawTree root metadata ("100644 blob " <> workspaceCoordinateText blob <> "\tA\0" <> "100644 blob " <> workspaceCoordinateText blob <> "\ta\0")
        readFlatTree metadata symlink >>= assertLeft
        readFlatTree metadata aliases >>= assertLeft,
      testCase "exact bytes and executable intent form an isolated tree without filters" $ fixture \root metadata parent -> do
        marker <- armHelpers root metadata
        blob <- right =<< storeBlob metadata "new dependency\r\n"
        attributes <- right =<< storeBlob metadata "* filter=hostile diff=hostile\n"
        tree <- right =<< storeTree metadata [GitEntry (workspaceCoordinate "dependency.txt") GitExecutable blob, GitEntry (workspaceCoordinate ".gitattributes") GitRegular attributes]
        result <- right =<< storeCommit metadata parent tree author now (fixtureOperationId "upgrade") (workspaceCoordinate "Upgrade dependency")
        git root ["--git-dir=" <> metadata, "show", Text.unpack (workspaceCoordinateText result) <> ":dependency.txt"] >>= (@?= "new dependency\r\n")
        entries <- git root ["--git-dir=" <> metadata, "ls-tree", Text.unpack (workspaceCoordinateText tree)]
        assertBool "mode retained" ("100755 blob " `Bytes.isInfixOf` entries)
        changedPaths metadata parent result >>= (@?= Right (map workspaceCoordinate [".gitattributes", "dependency.txt"]))
        patch <- right =<< objectDiff metadata parent result
        assertBool "bounded object diff" ("new dependency" `Bytes.isInfixOf` patch)
        doesFileExist marker >>= (@?= False)
        readHead metadata >>= (@?= Right parent),
      testCase "flat capture composes nested trees and refuses ambiguous prefixes" $ fixture \root metadata parent -> do
        original <- right =<< storeBlob metadata "old dependency\n"
        script <- right =<< storeBlob metadata "#!/bin/sh\ntrue\n"
        tree <- right =<< storeFlatTree metadata [GitEntry (workspaceCoordinate "dependency.txt") GitRegular original, GitEntry (workspaceCoordinate "src/tools/probe") GitExecutable script]
        git root ["--git-dir=" <> metadata, "show", Text.unpack (workspaceCoordinateText tree) <> ":src/tools/probe"] >>= (@?= "#!/bin/sh\ntrue\n")
        changedPaths metadata parent tree >>= (@?= Right [workspaceCoordinate "src/tools/probe"])
        storeFlatTree metadata [GitEntry (workspaceCoordinate "A/one") GitRegular script, GitEntry (workspaceCoordinate "a/two") GitRegular script] >>= assertLeft
        storeFlatTree metadata [GitEntry (workspaceCoordinate "file") GitRegular script, GitEntry (workspaceCoordinate "file/child") GitRegular script] >>= assertLeft
        storeFlatTree metadata [GitEntry (workspaceCoordinate "src/same") GitRegular script, GitEntry (workspaceCoordinate "src/same") GitRegular script] >>= assertLeft,
      testCase "retained commit publishes once and recovers acknowledgement loss" $ fixture \root metadata parent -> do
        marker <- armHelpers root metadata
        blob <- right =<< storeBlob metadata "upgrade\n"
        tree <- right =<< storeTree metadata [GitEntry (workspaceCoordinate "dependency.txt") GitRegular blob]
        result <- right =<< storeCommit metadata parent tree author now (fixtureOperationId "accepted-operation") (workspaceCoordinate "Upgrade")
        storeCommit metadata parent tree author now (fixtureOperationId "accepted-operation") (workspaceCoordinate "Upgrade") >>= (@?= Right result)
        publishCommit metadata parent result >>= (@?= Right ())
        publishCommit metadata parent result >>= (@?= Right ())
        readHead metadata >>= (@?= Right result)
        git root ["--git-dir=" <> metadata, "rev-list", "--count", "HEAD"] >>= (@?= "2\n")
        doesFileExist marker >>= (@?= False),
      testCase "a competing parent cannot overwrite a published commit" $ fixture \_ metadata parent -> do
        blob <- right =<< storeBlob metadata "upgrade\n"
        tree <- right =<< storeTree metadata [GitEntry (workspaceCoordinate "dependency.txt") GitRegular blob]
        one <- right =<< storeCommit metadata parent tree author now (fixtureOperationId "one") (workspaceCoordinate "Upgrade")
        two <- right =<< storeCommit metadata parent tree author now (fixtureOperationId "two") (workspaceCoordinate "Upgrade")
        assertBool "operation identity retained" (one /= two)
        publishCommit metadata parent one >>= (@?= Right ())
        publishCommit metadata parent two >>= assertLeft
        readHead metadata >>= (@?= Right one),
      testCase "publication refuses an unretained additional parent" $ fixture \root metadata parent -> do
        blob <- right =<< storeBlob metadata "upgrade\n"
        tree <- right =<< storeTree metadata [GitEntry (workspaceCoordinate "dependency.txt") GitRegular blob]
        other <- right =<< storeCommit metadata parent tree author now (fixtureOperationId "other") (workspaceCoordinate "Other")
        merged <- Text.strip . Encoding.decodeUtf8 <$> git root ["--git-dir=" <> metadata, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit-tree", Text.unpack (workspaceCoordinateText tree), "-p", Text.unpack (workspaceCoordinateText parent), "-p", Text.unpack (workspaceCoordinateText other), "-m", "Unexpected merge"]
        publishCommit metadata parent (workspaceCoordinate merged) >>= assertLeft
        readHead metadata >>= (@?= Right parent),
      testCase "malicious tree names, aliases, modes and absent objects refuse" $ fixture \_ metadata _ -> do
        assertBool "unsupported mode refuses before tree admission" (case parseGitMode "120000" of Left _ -> True; _ -> False)
        blob <- right =<< storeBlob metadata "safe"
        mapM_
          (\entry -> storeTree metadata [entry] >>= assertLeft)
          [GitEntry (workspaceCoordinate "../escape") GitRegular blob, GitEntry (workspaceCoordinate ".Git") GitRegular blob, GitEntry (workspaceCoordinate "dir/file") GitRegular blob, GitEntry (workspaceCoordinate "name\n") GitRegular blob, GitEntry (workspaceCoordinate "é") GitRegular blob, GitEntry (workspaceCoordinate "missing") GitRegular (workspaceCoordinate (Text.replicate 40 "0"))]
        storeTree metadata [GitEntry (workspaceCoordinate "A") GitRegular blob, GitEntry (workspaceCoordinate "a") GitRegular blob] >>= assertLeft
        storeTree metadata [GitEntry (workspaceCoordinate "wrong-type") GitTree blob] >>= assertLeft,
      testCase "oversized blobs and diffs return a bounded refusal" $ fixture \root metadata parent -> do
        storeBlob metadata (Bytes.replicate 16777217 120) >>= assertLeft
        large <- right =<< storeBlob metadata (Bytes.replicate 1048577 120)
        git root ["--git-dir=" <> metadata, "cat-file", "-s", Text.unpack (workspaceCoordinateText large)] >>= (@?= "1048577\n")
        blob <- right =<< storeBlob metadata (Bytes.replicate 262144 120)
        tree <- right =<< storeTree metadata [GitEntry (workspaceCoordinate "dependency.txt") GitRegular blob]
        objectDiff metadata parent tree >>= assertLeft,
      testCase "exposed metadata refuses without permission repair" $ fixture \_ metadata _ -> do
        setFileMode metadata 0o755
        storeBlob metadata "private" >>= assertLeft
    ]

fixture :: (FilePath -> FilePath -> WorkspaceCoordinate "git-object" -> IO a) -> IO a
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
    tree <- right =<< storeTree metadata [GitEntry (workspaceCoordinate "dependency.txt") GitRegular blob]
    parent <- Text.strip . Encoding.decodeUtf8 <$> git root ["--git-dir=" <> metadata, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit-tree", "-m", "Base", Text.unpack (workspaceCoordinateText tree)]
    _ <- git root ["--git-dir=" <> metadata, "update-ref", "--no-deref", "HEAD", Text.unpack parent]
    use root metadata (workspaceCoordinate parent)

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
  _ <- git root ["--git-dir=" <> metadata, "-c", "core.hooksPath=" <> metadata </> "hooks", "update-ref", "refs/test/hook-control", Text.unpack (workspaceCoordinateText parent)]
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
author = GitAuthor (workspaceCoordinate "Shikigami Fixture") (workspaceCoordinate "fixture@example.invalid")

now :: UTCTime
now = UTCTime (fromGregorian 2026 10 30) 0

rawTree :: FilePath -> FilePath -> Text.Text -> IO (WorkspaceCoordinate "git-object")
rawTree root metadata body = workspaceCoordinate . Text.strip . Encoding.decodeUtf8 <$> (right =<< runWorkspaceGitInput root 1048576 [] ["--git-dir=" <> metadata, "mktree", "-z"] (Encoding.encodeUtf8 body))
