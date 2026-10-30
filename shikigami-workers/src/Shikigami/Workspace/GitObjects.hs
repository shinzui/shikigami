-- | Trusted object plumbing only, with no worktree reads, filters, hooks or
-- external diff programs. Callers must hold the workspace lock, establish
-- settlement and obtain fresh exact authority before IO. This is no adapter.
module Shikigami.Workspace.GitObjects
  ( GitEntry (..),
    GitAuthor (..),
    storeBlob,
    storeTree,
    storeCommit,
    readHead,
    publishCommit,
    changedPaths,
    objectDiff,
  )
where

import Control.Monad (unless)
import Data.ByteString qualified as Bytes
import Data.List (nub)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Prelude (FromJSON, Generic, ToJSON, toJSON)
import Shikigami.Workspace.ContainedFile (checkPrivateDirectory)
import Shikigami.Workspace.Git (runWorkspaceGitInput)
import Shikigami.Workspace.Instructions (validWorkspacePath)
import Shikigami.Workspace.Types (WorkspaceError (..))

data GitEntry = GitEntry {name :: !Text.Text, mode :: !Text.Text, objectId :: !Text.Text}
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GitAuthor = GitAuthor {name :: !Text.Text, email :: !Text.Text}
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

storeBlob :: FilePath -> Bytes.ByteString -> IO (Either WorkspaceError Text.Text)
storeBlob metadata content
  | Bytes.length content > 262144 = pure refused
  | otherwise = objectId <$> git metadata 65 [] ["hash-object", "--no-filters", "-w", "--stdin"] content

-- Each call builds one directory; a caller builds children first. mktree
-- validates that every referenced object exists and has the requested type.
-- mori://git/git, Documentation/git-mktree.adoc (artifact URI pending).
storeTree :: FilePath -> [GitEntry] -> IO (Either WorkspaceError Text.Text)
storeTree metadata entries
  | length entries > 10000 || length (nub (map (Text.toCaseFold . (.name)) entries)) /= length entries || not (all valid entries) = pure refused
  | otherwise = objectId <$> git metadata 65 [] ["mktree", "-z"] (Encoding.encodeUtf8 (Text.concat (map line entries)))
  where
    valid entry = component entry.name && entry.mode `elem` ["100644", "100755", "040000"] && validObject entry.objectId
    line entry = entry.mode <> (if entry.mode == "040000" then " tree " else " blob ") <> entry.objectId <> "\t" <> entry.name <> "\0"

-- The caller retains this exact object, parent, tree and timestamp before
-- publishing HEAD. Rebuilding an object never invokes user commit hooks.
-- mori://git/git, Documentation/git-commit-tree.adoc (artifact URI pending).
storeCommit :: FilePath -> Text.Text -> Text.Text -> GitAuthor -> UTCTime -> OperationId -> Text.Text -> IO (Either WorkspaceError Text.Text)
storeCommit metadata parent tree author at operation message
  | not (validObject parent && validObject tree && identity author.name && identity author.email) || seconds < 1 || seconds > 9223372036854775807 || Text.null (Text.strip message) || Bytes.length (Encoding.encodeUtf8 message) > 4096 || Text.any (== '\0') message = pure refused
  | otherwise = objectId <$> git metadata 65 environment ["commit-tree", "--no-gpg-sign", treeString, "-p", Text.unpack parent] body
  where
    treeString = Text.unpack tree
    seconds = floor (utcTimeToPOSIXSeconds at) :: Integer
    date = show seconds <> " +0000"
    environment = [(prefix <> suffix, value) | prefix <- ["GIT_AUTHOR_", "GIT_COMMITTER_"], (suffix, value) <- [("NAME", Text.unpack author.name), ("EMAIL", Text.unpack author.email), ("DATE", date)]]
    body = Encoding.encodeUtf8 (Text.stripEnd message <> "\n\nShikigami-Operation: " <> versionedDigest "shikigami.workspace-git-operation/1" (toJSON operation) <> "\n")
    identity value = not (Text.null (Text.strip value)) && Text.length value <= 256 && not (Text.any (\c -> c < ' ' || c `elem` ("<>\DEL" :: String)) value)

readHead :: FilePath -> IO (Either WorkspaceError Text.Text)
readHead metadata = objectId <$> git metadata 65 [] ["rev-parse", "--verify", "HEAD^{commit}"] ""

-- A lost update acknowledgement recovers by inspecting the exact result.
-- Another parent never gets overwritten. --no-deref prevents branch traversal.
-- mori://git/git, Documentation/git-update-ref.adoc (artifact URI pending).
publishCommit :: FilePath -> Text.Text -> Text.Text -> IO (Either WorkspaceError ())
publishCommit metadata parent result
  | not (validObject parent && validObject result) || parent == result = pure refused
  | otherwise = do
      ancestry <- git metadata 132 [] ["rev-list", "--parents", "-n", "1", Text.unpack result] ""
      current <- readHead metadata
      if ancestry /= Right (Encoding.encodeUtf8 (result <> " " <> parent <> "\n"))
        then pure refused
        else case current of
          Right headId | headId == result -> pure (Right ())
          Right headId | headId == parent -> do
            _ <- git metadata 1 [] ["update-ref", "--no-deref", "HEAD", Text.unpack result, Text.unpack parent] ""
            observed <- readHead metadata
            pure (if observed == Right result then Right () else refused)
          _ -> pure refused

changedPaths :: FilePath -> Text.Text -> Text.Text -> IO (Either WorkspaceError [Text.Text])
changedPaths metadata left right
  | not (validObject left && validObject right) = pure refused
  | otherwise = do
      bytes <- git metadata 262144 [] (diffArguments <> ["--name-only", "-z", Text.unpack left, Text.unpack right, "--"]) ""
      pure do
        body <- bytes
        text <- either (const refused) Right (Encoding.decodeUtf8' body)
        let paths = if Text.null text then [] else init (Text.splitOn "\0" text)
        unless (Text.null text || Text.isSuffixOf "\0" text) refused
        unless (all (\path -> validWorkspacePath path && Text.all (< '\DEL') path) paths) refused
        pure paths

objectDiff :: FilePath -> Text.Text -> Text.Text -> IO (Either WorkspaceError Bytes.ByteString)
objectDiff metadata left right
  | not (validObject left && validObject right) = pure refused
  | otherwise = git metadata 262144 [] (diffArguments <> ["--binary", Text.unpack left, Text.unpack right, "--"]) ""

diffArguments :: [String]
diffArguments = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames"]

git :: FilePath -> Int -> [(String, String)] -> [String] -> Bytes.ByteString -> IO (Either WorkspaceError Bytes.ByteString)
git metadata limit environment arguments input = do
  private <- checkPrivateDirectory metadata
  case private of
    Left _ -> pure refused
    Right () -> runWorkspaceGitInput metadata limit environment (["--git-dir=" <> metadata, "-c", "protocol.allow=never", "-c", "protocol.file.allow=never", "-c", "core.fsmonitor=false", "-c", "core.attributesFile=/dev/null", "-c", "diff.external=", "-c", "commit.gpgSign=false", "-c", "core.fsync=all", "-c", "core.fsyncMethod=fsync"] <> arguments) input

objectId :: Either WorkspaceError Bytes.ByteString -> Either WorkspaceError Text.Text
objectId value = do
  bytes <- value
  text <- either (const refused) Right (Encoding.decodeUtf8' bytes)
  let candidate = Text.dropEnd 1 text
  unless (Text.isSuffixOf "\n" text && validObject candidate) refused
  pure candidate

validObject :: Text.Text -> Bool
validObject value = Text.length value `elem` [40, 64] && Text.all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') value

component :: Text.Text -> Bool
component value = validWorkspacePath value && Text.length value <= 255 && not (Text.any (== '/') value) && Text.all (< '\DEL') value

refused :: Either WorkspaceError a
refused = Left WorkspaceAllocationRefused
