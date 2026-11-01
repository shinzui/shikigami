{-# LANGUAGE DataKinds #-}

-- | Trusted object plumbing only, with no worktree reads, filters, hooks or
-- external diff programs. Callers must hold the workspace lock, establish
-- settlement and obtain fresh exact authority before IO. This is no adapter.
module Shikigami.Workspace.GitObjects
  ( GitEntry (..),
    GitAuthor (..),
    storeBlob,
    storeTree,
    storeFlatTree,
    storeCommit,
    readHead,
    readCommit,
    readFlatTree,
    readBlob,
    publishCommit,
    verifyPublishedCommit,
    changedPaths,
    objectDiff,
  )
where

import Control.Monad (unless)
import Data.ByteString qualified as Bytes
import Data.Generics.Labels ()
import Data.List (inits, nub)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Prelude (FromJSON, Generic, ToJSON, toJSON, (&), (.~))
import Shikigami.Workspace.ContainedFile (checkPrivateDirectory)
import Shikigami.Workspace.Git (runWorkspaceGitInput)
import Shikigami.Workspace.GitTypes (GitCandidate (..), validGitCandidate)
import Shikigami.Workspace.Instructions (validWorkspacePath)
import Shikigami.Workspace.Types (WorkspaceError (..))
import Shikigami.Workspace.Value

data GitEntry = GitEntry {name :: !(WorkspaceCoordinate "relative-path"), mode :: !(GitMode), objectId :: !(WorkspaceCoordinate "git-object")}
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GitAuthor = GitAuthor {name :: !(WorkspaceCoordinate "git-author"), email :: !(WorkspaceCoordinate "git-email")}
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

storeBlob :: FilePath -> Bytes.ByteString -> IO (Either WorkspaceError (WorkspaceCoordinate "git-object"))
storeBlob metadata content
  | Bytes.length content > 16777216 = pure refused
  | otherwise = objectId <$> git metadata 65 [] ["hash-object", "--no-filters", "-w", "--stdin"] content

-- Each call builds one directory; a caller builds children first. mktree
-- validates that every referenced object exists and has the requested type.
-- mori://git/git, Documentation/git-mktree.adoc (artifact URI pending).
storeTree :: FilePath -> [GitEntry] -> IO (Either WorkspaceError (WorkspaceCoordinate "git-object"))
storeTree metadata entries
  | length entries > 10000 || length (nub (map (Text.toCaseFold . workspaceCoordinateText . (.name)) entries)) /= length entries || not (all valid entries) = pure refused
  | otherwise = objectId <$> git metadata 65 [] ["mktree", "-z"] (Encoding.encodeUtf8 (Text.concat (map line entries)))
  where
    valid entry = component entry.name && entry.mode `elem` [GitRegular, GitExecutable, GitTree] && validObject entry.objectId
    line entry = gitModeText entry.mode <> (if entry.mode == GitTree then " tree " else " blob ") <> workspaceCoordinateText entry.objectId <> "\t" <> workspaceCoordinateText entry.name <> "\0"

-- Compose a complete, bounded flat manifest without a Git index or worktree
-- traversal. A file/directory collision and case aliases at any depth refuse.
storeFlatTree :: FilePath -> [GitEntry] -> IO (Either WorkspaceError (WorkspaceCoordinate "git-object"))
storeFlatTree metadata entries
  | length entries > 100000 || length entries /= Set.size (Set.fromList paths) || Set.size prefixes /= Set.size (Set.map Text.toCaseFold prefixes) || not (all valid entries) = pure refused
  | otherwise = build entries
  where
    paths = map (workspaceCoordinateText . (.name)) entries
    prefixes = Set.fromList [Text.intercalate "/" prefix | path <- paths, prefix <- drop 1 (inits (Text.splitOn "/" path))]
    valid entry = validWorkspacePath (workspaceCoordinateText entry.name) && Text.all (< '\DEL') (workspaceCoordinateText entry.name) && length (Text.splitOn "/" (workspaceCoordinateText entry.name)) <= 128 && entry.mode `elem` [GitRegular, GitExecutable] && validObject entry.objectId
    build current = do
      let groups = Map.fromListWith (<>) [(Text.takeWhile (/= '/') (workspaceCoordinateText entry.name), [entry]) | entry <- current]
      children <- traverse child (Map.toAscList groups)
      case sequence children of Left err -> pure (Left err); Right nodes -> storeTree metadata nodes
    child (name, [entry]) | entry.name == workspaceCoordinate name = pure (Right entry)
    child (name, group)
      | any ((== workspaceCoordinate name) . (.name)) group = pure refused
      | otherwise = do
          nested <- build [entry & #name .~ workspaceCoordinate (Text.drop (Text.length name + 1) (workspaceCoordinateText entry.name)) | entry <- group]
          pure (GitEntry (workspaceCoordinate name) GitTree <$> nested)

-- The caller retains this exact object, parent, tree and timestamp before
-- publishing HEAD. Rebuilding an object never invokes user commit hooks.
-- mori://git/git, Documentation/git-commit-tree.adoc (artifact URI pending).
storeCommit :: FilePath -> WorkspaceCoordinate "git-object" -> WorkspaceCoordinate "git-object" -> GitAuthor -> UTCTime -> OperationId -> WorkspaceCoordinate "commit-message" -> IO (Either WorkspaceError (WorkspaceCoordinate "git-object"))
storeCommit metadata parent tree author at operation messageClaim
  | not (validObject parent && validObject tree && identity (workspaceCoordinateText author.name) && identity (workspaceCoordinateText author.email)) || seconds < 1 || seconds > 9223372036854775807 || Text.null (Text.strip message) || Bytes.length (Encoding.encodeUtf8 message) > 4096 || Text.any (== '\0') message = pure refused
  | otherwise = objectId <$> git metadata 65 environment ["commit-tree", "--no-gpg-sign", treeString, "-p", Text.unpack (workspaceCoordinateText parent)] body
  where
    message = workspaceCoordinateText messageClaim
    treeString = Text.unpack (workspaceCoordinateText tree)
    seconds = floor (utcTimeToPOSIXSeconds at) :: Integer
    date = show seconds <> " +0000"
    environment = [(prefix <> suffix, value) | prefix <- ["GIT_AUTHOR_", "GIT_COMMITTER_"], (suffix, value) <- [("NAME", Text.unpack (workspaceCoordinateText author.name)), ("EMAIL", Text.unpack (workspaceCoordinateText author.email)), ("DATE", date)]]
    body = Encoding.encodeUtf8 (Text.stripEnd message <> "\n\nShikigami-Operation: " <> versionedDigest "shikigami.workspace-git-operation/1" (toJSON operation) <> "\n")
    identity value = not (Text.null (Text.strip value)) && Text.length value <= 256 && not (Text.any (\c -> c < ' ' || c `elem` ("<>\DEL" :: String)) value)

readHead :: FilePath -> IO (Either WorkspaceError (WorkspaceCoordinate "git-object"))
readHead metadata = objectId <$> git metadata 65 [] ["rev-parse", "--verify", "HEAD^{commit}"] ""

-- Read only exact object ids, with a separate type check: cat-file may otherwise
-- peel a tag. No revision expression, worktree, helper or transport is accepted.
-- mori://git/git, Documentation/git-cat-file.adoc and
-- Documentation/git-ls-tree.adoc (artifact URIs pending).
readCommit :: FilePath -> WorkspaceCoordinate "git-object" -> IO (Either WorkspaceError (WorkspaceCoordinate "git-object", [WorkspaceCoordinate "git-object"]))
readCommit metadata object
  | not (validObject object) = pure refused
  | otherwise = do
      kind <- git metadata 16 [] ["cat-file", "-t", Text.unpack (workspaceCoordinateText object)] ""
      bytes <- if kind == Right "commit\n" then git metadata 65536 [] ["cat-file", "commit", Text.unpack (workspaceCoordinateText object)] "" else pure refused
      pure do
        body <- bytes
        text <- either (const refused) Right (Encoding.decodeUtf8' body)
        let headers = Text.lines (fst (Text.breakOn "\n\n" text))
            trees = [Text.drop 5 line | line <- headers, Text.isPrefixOf "tree " line]
            parents = [Text.drop 7 line | line <- headers, Text.isPrefixOf "parent " line]
        case trees of
          [tree] | all (validObject . workspaceCoordinate) (tree : parents) && length parents <= 16 -> Right (workspaceCoordinate tree, map workspaceCoordinate parents)
          _ -> refused

readFlatTree :: FilePath -> WorkspaceCoordinate "git-object" -> IO (Either WorkspaceError [GitEntry])
readFlatTree metadata object
  | not (validObject object) = pure refused
  | otherwise = do
      kind <- git metadata 16 [] ["cat-file", "-t", Text.unpack (workspaceCoordinateText object)] ""
      bytes <- if kind == Right "tree\n" then git metadata 16777216 [] ["ls-tree", "-r", "-z", "--full-tree", Text.unpack (workspaceCoordinateText object)] "" else pure refused
      pure do
        body <- bytes
        text <- either (const refused) Right (Encoding.decodeUtf8' body)
        unless (Text.null text || Text.isSuffixOf "\0" text) refused
        entries <- traverse parse (if Text.null text then [] else init (Text.splitOn "\0" text))
        let paths = map (workspaceCoordinateText . (.name)) entries
            prefixes = Set.fromList [Text.intercalate "/" prefix | path <- paths, prefix <- drop 1 (inits (Text.splitOn "/" path))]
            directories = Set.fromList [Text.intercalate "/" prefix | path <- paths, prefix <- drop 1 (init (inits (Text.splitOn "/" path)))]
        unless (length entries <= 10000 && length paths == Set.size (Set.fromList paths) && Set.size prefixes == Set.size (Set.map Text.toCaseFold prefixes) && Set.null (Set.intersection (Set.fromList paths) directories)) refused
        pure entries
  where
    parse line = case Text.breakOn "\t" line of
      (header, suffix) | not (Text.null suffix) -> case Text.words header of
        [mode, "blob", object] | mode `elem` ["100644", "100755"] && validObject (workspaceCoordinate object) && validWorkspacePath (Text.drop 1 suffix) && Text.all (< '\DEL') suffix && length (Text.splitOn "/" suffix) <= 128 -> Right (GitEntry (workspaceCoordinate (Text.drop 1 suffix)) (if mode == "100644" then GitRegular else GitExecutable) (workspaceCoordinate object))
        _ -> refused
      _ -> refused

readBlob :: FilePath -> Int -> WorkspaceCoordinate "git-object" -> IO (Either WorkspaceError Bytes.ByteString)
readBlob metadata limit object
  | not (validObject object) || limit < 0 || limit > 16777216 = pure refused
  | otherwise = do
      kind <- git metadata 16 [] ["cat-file", "-t", Text.unpack (workspaceCoordinateText object)] ""
      if kind == Right "blob\n" then git metadata limit [] ["cat-file", "blob", Text.unpack (workspaceCoordinateText object)] "" else pure refused

-- A lost update acknowledgement recovers by inspecting the exact result.
-- Another parent never gets overwritten. --no-deref prevents branch traversal.
-- mori://git/git, Documentation/git-update-ref.adoc (artifact URI pending).
publishCommit :: FilePath -> WorkspaceCoordinate "git-object" -> WorkspaceCoordinate "git-object" -> IO (Either WorkspaceError ())
publishCommit metadata parent result
  | not (validObject parent && validObject result) || parent == result = pure refused
  | otherwise = do
      ancestry <- git metadata 132 [] ["rev-list", "--parents", "-n", "1", Text.unpack (workspaceCoordinateText result)] ""
      current <- readHead metadata
      if ancestry /= Right (Encoding.encodeUtf8 (workspaceCoordinateText result <> " " <> workspaceCoordinateText parent <> "\n"))
        then pure refused
        else case current of
          Right headId | headId == result -> pure (Right ())
          Right headId | headId == parent -> do
            _ <- git metadata 1 [] ["update-ref", "--no-deref", "HEAD", Text.unpack (workspaceCoordinateText result), Text.unpack (workspaceCoordinateText parent)] ""
            observed <- readHead metadata
            pure (if observed == Right result then Right () else refused)
          _ -> pure refused

-- Factual observation only: this can never advance HEAD. A retained prepared
-- plan is insufficient; the exact result, its one parent and tree must agree.
verifyPublishedCommit :: FilePath -> GitCandidate -> IO (Either WorkspaceError Bool)
verifyPublishedCommit metadata candidate
  | not (validGitCandidate candidate) = pure refused
  | otherwise = do
      current <- readHead metadata
      case current of
        Left err -> pure (Left err)
        Right headId | headId /= candidate.result -> pure (Right False)
        Right _ -> do
          ancestry <- git metadata 132 [] ["rev-list", "--parents", "-n", "1", Text.unpack (workspaceCoordinateText candidate.result)] ""
          tree <- objectId <$> git metadata 65 [] ["rev-parse", "--verify", Text.unpack (workspaceCoordinateText candidate.result) <> "^{tree}"] ""
          pure do
            actual <- ancestry
            object <- tree
            unless (actual == Encoding.encodeUtf8 (workspaceCoordinateText candidate.result <> " " <> workspaceCoordinateText candidate.parent <> "\n") && object == candidate.tree) refused
            pure True

changedPaths :: FilePath -> WorkspaceCoordinate "git-object" -> WorkspaceCoordinate "git-object" -> IO (Either WorkspaceError [WorkspaceCoordinate "relative-path"])
changedPaths metadata left right
  | not (validObject left && validObject right) = pure refused
  | otherwise = do
      bytes <- git metadata 262144 [] (diffArguments <> ["--name-only", "-z", Text.unpack (workspaceCoordinateText left), Text.unpack (workspaceCoordinateText right), "--"]) ""
      pure do
        body <- bytes
        text <- either (const refused) Right (Encoding.decodeUtf8' body)
        let paths = if Text.null text then [] else init (Text.splitOn "\0" text)
        unless (Text.null text || Text.isSuffixOf "\0" text) refused
        unless (all (\path -> validWorkspacePath path && Text.all (< '\DEL') path) paths) refused
        pure (map workspaceCoordinate paths)

objectDiff :: FilePath -> WorkspaceCoordinate "git-object" -> WorkspaceCoordinate "git-object" -> IO (Either WorkspaceError Bytes.ByteString)
objectDiff metadata left right
  | not (validObject left && validObject right) = pure refused
  | otherwise = git metadata 262144 [] (diffArguments <> ["--binary", Text.unpack (workspaceCoordinateText left), Text.unpack (workspaceCoordinateText right), "--"]) ""

diffArguments :: [String]
diffArguments = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames"]

git :: FilePath -> Int -> [(String, String)] -> [String] -> Bytes.ByteString -> IO (Either WorkspaceError Bytes.ByteString)
git metadata limit environment arguments input = do
  private <- checkPrivateDirectory metadata
  case private of
    Left _ -> pure refused
    Right () -> runWorkspaceGitInput metadata limit environment (["--git-dir=" <> metadata, "-c", "protocol.allow=never", "-c", "protocol.file.allow=never", "-c", "core.fsmonitor=false", "-c", "core.attributesFile=/dev/null", "-c", "diff.external=", "-c", "commit.gpgSign=false", "-c", "core.fsync=all", "-c", "core.fsyncMethod=fsync"] <> arguments) input

objectId :: Either WorkspaceError Bytes.ByteString -> Either WorkspaceError (WorkspaceCoordinate "git-object")
objectId value = do
  bytes <- value
  text <- either (const refused) Right (Encoding.decodeUtf8' bytes)
  let candidate = Text.dropEnd 1 text
  unless (Text.isSuffixOf "\n" text && validObject (workspaceCoordinate candidate)) refused
  pure (workspaceCoordinate candidate)

validObject :: WorkspaceCoordinate "git-object" -> Bool
validObject claim =
  let value = workspaceCoordinateText claim
   in Text.length value `elem` [40, 64] && Text.all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') value

component :: WorkspaceCoordinate "relative-path" -> Bool
component claim =
  let value = workspaceCoordinateText claim
   in validWorkspacePath value && Text.length value <= 255 && not (Text.any (== '/') value) && Text.all (< '\DEL') value

refused :: Either WorkspaceError a
refused = Left WorkspaceAllocationRefused
