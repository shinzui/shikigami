{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A bounded, read-only workspace capability for one-off agent runs.
module Shikigami.Agent.Capability.Workspace
  ( WorkspaceScope (..),
    WorkspaceError (..),
    renderWorkspaceError,
    resolveWorkspaceScope,
    resolveWorkspacePath,
    workspaceReadId,
    workspaceReadDescriptor,
    workspaceReadProvider,
    maxReadBytes,
    maxVisitedFiles,
    maxTraversalDepth,
    maxSearchMatches,
    maxGlobResults,
    maxResponseBytes,
  )
where

import Control.Exception (IOException, displayException, try)
import Control.Monad (foldM)
import Data.Aeson (ToJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAlphaNum)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Effectful (Eff, (:>))
import Effectful.Dispatch.Static (unsafeEff_)
import Effectful.Error.Static (Error, throwError)
import GHC.Generics (Generic)
import Shikigami.Capability.Overlay
  ( CapabilityDescriptor (..),
    CapabilityId,
    CapabilityOperationClass (Observation),
    CapabilityToolDescriptor (..),
    mkCapabilityId,
    mkCapabilityRevision,
  )
import Shikigami.Capability.Provider
  ( CapabilityAcquireError (..),
    CapabilityLease (..),
    CapabilityProvider (..),
  )
import Shikumi.Error (ShikumiError (ProviderFailure, ValidationFailure))
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Tool (SomeTool (..), mkTool)
import System.Directory
  ( canonicalizePath,
    doesDirectoryExist,
    doesFileExist,
    getFileSize,
    listDirectory,
    pathIsSymbolicLink,
  )
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, makeRelative, splitDirectories, takeFileName, (</>))
import System.Process (proc, readCreateProcessWithExitCode)
import Text.Regex.TDFA
  ( CompOption (..),
    Regex,
    defaultCompOpt,
    defaultExecOpt,
    makeRegexOptsM,
    matchTest,
    (=~),
  )

-- | The canonical absolute root of one Git worktree.
data WorkspaceScope = WorkspaceScope
  { root :: !FilePath
  }
  deriving stock (Eq, Show, Generic)

data WorkspaceError
  = WorkspaceNotFound !FilePath
  | NotGitWorktree !FilePath
  | InvalidWorkspaceRoot !FilePath
  | InvalidWorkspacePath !FilePath
  | WorkspacePathEscapes !FilePath
  | WorkspaceSymlinkRefused !FilePath
  | WorkspaceExcludedPath !FilePath
  | WorkspaceNotAFile !FilePath
  | WorkspaceNotADirectory !FilePath
  | WorkspaceBinaryFile !FilePath
  | WorkspaceInvalidPattern !Text
  | WorkspaceLimitExceeded !Text
  | WorkspaceIoFailed !Text
  deriving stock (Eq, Show, Generic)

renderWorkspaceError :: WorkspaceError -> Text
renderWorkspaceError = \case
  WorkspaceNotFound path -> "workspace directory does not exist: " <> Text.pack path
  NotGitWorktree path -> "not a Git worktree: " <> Text.pack path
  InvalidWorkspaceRoot path -> "Git returned an invalid worktree root: " <> Text.pack path
  InvalidWorkspacePath path -> "invalid workspace-relative path: " <> Text.pack path
  WorkspacePathEscapes path -> "workspace path escapes the worktree: " <> Text.pack path
  WorkspaceSymlinkRefused path -> "workspace symlink traversal is refused: " <> Text.pack path
  WorkspaceExcludedPath path -> "workspace path is excluded: " <> Text.pack path
  WorkspaceNotAFile path -> "workspace path is not a regular file: " <> Text.pack path
  WorkspaceNotADirectory path -> "workspace path is not a directory: " <> Text.pack path
  WorkspaceBinaryFile path -> "workspace file is binary: " <> Text.pack path
  WorkspaceInvalidPattern patternText -> "invalid workspace search pattern: " <> patternText
  WorkspaceLimitExceeded detail -> "workspace limit exceeded: " <> detail
  WorkspaceIoFailed detail -> "workspace IO failed: " <> detail

-- | Resolve an explicit directory, or the current directory when absent, to
-- the canonical root reported by Git. The subprocess receives structured
-- arguments and never changes this process's current directory.
resolveWorkspaceScope :: Maybe FilePath -> IO (Either WorkspaceError WorkspaceScope)
resolveWorkspaceScope requested = do
  attempted <- try @IOException (resolveWorkspaceScopeUnchecked requested)
  pure case attempted of
    Left exception -> Left (WorkspaceIoFailed (Text.pack (displayException exception)))
    Right result -> result

resolveWorkspaceScopeUnchecked :: Maybe FilePath -> IO (Either WorkspaceError WorkspaceScope)
resolveWorkspaceScopeUnchecked requested = do
  let candidate = maybe "." id requested
  exists <- doesDirectoryExist candidate
  if not exists
    then pure (Left (WorkspaceNotFound candidate))
    else do
      (exitCode, stdout, _) <- readCreateProcessWithExitCode process ""
      case exitCode of
        ExitFailure _ -> pure (Left (NotGitWorktree candidate))
        ExitSuccess -> validateRoot (trimLine stdout)
  where
    process = proc "git" ["-C", maybe "." id requested, "rev-parse", "--show-toplevel"]

    validateRoot answer
      | null answer || not (isAbsolute answer) = pure (Left (InvalidWorkspaceRoot answer))
      | otherwise = do
          exists <- doesDirectoryExist answer
          if not exists
            then pure (Left (InvalidWorkspaceRoot answer))
            else do
              canonical <- canonicalizePath answer
              pure (Right WorkspaceScope {root = canonical})

-- | Resolve one existing file or directory beneath the workspace. Absolute,
-- traversal, excluded, and symlinked paths are refused before canonicalization.
resolveWorkspacePath :: WorkspaceScope -> FilePath -> IO (Either WorkspaceError FilePath)
resolveWorkspacePath scope raw = resolveExistingPath scope False raw

data WorkspaceReadRequest = WorkspaceReadRequest
  { path :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema, FromModel)

instance Validatable WorkspaceReadRequest

data WorkspaceReadResponse = WorkspaceReadResponse
  { content :: !Text,
    bytesRead :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data WorkspaceGrepRequest = WorkspaceGrepRequest
  { patternText :: !Text,
    path :: !(Maybe Text),
    ignoreCase :: !(Maybe Bool)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema, FromModel)

instance Validatable WorkspaceGrepRequest

data WorkspaceGrepMatch = WorkspaceGrepMatch
  { file :: !Text,
    line :: !Int,
    text :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data WorkspaceGrepResponse = WorkspaceGrepResponse
  { matches :: ![WorkspaceGrepMatch]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data WorkspaceGlobRequest = WorkspaceGlobRequest
  { patternText :: !Text,
    path :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema, FromModel)

instance Validatable WorkspaceGlobRequest

data WorkspaceGlobResponse = WorkspaceGlobResponse
  { paths :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

workspaceReadId :: CapabilityId
workspaceReadId =
  case mkCapabilityId "workspace.read" of
    Left err -> error (show err)
    Right capability -> capability

workspaceReadDescriptor :: CapabilityDescriptor
workspaceReadDescriptor =
  CapabilityDescriptor
    { capability = workspaceReadId,
      revision =
        case mkCapabilityRevision "1" of
          Left err -> error (show err)
          Right value -> value,
      tools =
        [ CapabilityToolDescriptor {name = "read", operationClass = Observation},
          CapabilityToolDescriptor {name = "grep", operationClass = Observation},
          CapabilityToolDescriptor {name = "glob", operationClass = Observation}
        ]
    }

workspaceReadProvider :: WorkspaceScope -> CapabilityProvider
workspaceReadProvider scope =
  CapabilityProvider
    { descriptor = workspaceReadDescriptor,
      acquire = \_scope -> do
        valid <- validateScopeStillPresent scope
        pure case valid of
          Left err -> Left (CapabilityAcquireError (renderWorkspaceError err))
          Right () ->
            Right
              CapabilityLease
                { descriptor = workspaceReadDescriptor,
                  tools = workspaceTools scope,
                  release = pure (Right ())
                }
    }

workspaceTools :: WorkspaceScope -> [SomeTool]
workspaceTools scope =
  [ SomeTool
      ( mkTool "read" "Read one bounded UTF-8 file inside the selected Git worktree." \WorkspaceReadRequest {path} ->
          runWorkspaceTool (readWorkspaceFile scope (Text.unpack path))
      ),
    SomeTool
      ( mkTool "grep" "Search bounded UTF-8 files inside the selected Git worktree." \WorkspaceGrepRequest {patternText, path, ignoreCase} ->
          runWorkspaceTool (grepWorkspace scope patternText (Text.unpack <$> path) (maybe False id ignoreCase))
      ),
    SomeTool
      ( mkTool "glob" "List bounded file paths matching a glob inside the selected Git worktree." \WorkspaceGlobRequest {patternText, path} ->
          runWorkspaceTool (globWorkspace scope patternText (Text.unpack <$> path))
      )
  ]

runWorkspaceTool :: (Error ShikumiError :> es) => IO (Either WorkspaceError value) -> Eff es value
runWorkspaceTool action = do
  attempted <- unsafeEff_ (try @IOException action)
  case attempted of
    Left exception -> throwError (ProviderFailure (Text.pack (displayException exception)))
    Right (Left err) -> throwError (ValidationFailure (renderWorkspaceError err))
    Right (Right value) -> pure value

readWorkspaceFile :: WorkspaceScope -> FilePath -> IO (Either WorkspaceError WorkspaceReadResponse)
readWorkspaceFile scope raw = do
  resolved <- resolveExistingPath scope False raw
  case resolved of
    Left err -> pure (Left err)
    Right absolute -> do
      regular <- doesFileExist absolute
      if not regular
        then pure (Left (WorkspaceNotAFile raw))
        else do
          size <- getFileSize absolute
          if size > fromIntegral maxReadBytes
            then pure (Left (WorkspaceLimitExceeded ("file exceeds " <> tshow maxReadBytes <> " bytes")))
            else do
              bytes <- BS.readFile absolute
              if isBinary bytes
                then pure (Left (WorkspaceBinaryFile raw))
                else case TE.decodeUtf8' bytes of
                  Left _ -> pure (Left (WorkspaceBinaryFile raw))
                  Right content ->
                    pure (boundedResponse "read" (WorkspaceReadResponse {content, bytesRead = BS.length bytes}))

grepWorkspace :: WorkspaceScope -> Text -> Maybe FilePath -> Bool -> IO (Either WorkspaceError WorkspaceGrepResponse)
grepWorkspace scope patternText requestedRoot ignoreCase =
  case compileRegex patternText ignoreCase of
    Nothing -> pure (Left (WorkspaceInvalidPattern patternText))
    Just regex -> do
      walked <- walkWorkspace scope requestedRoot
      case walked of
        Left err -> pure (Left err)
        Right paths -> collectMatches regex paths [] 0
  where
    collectMatches _ [] accumulated _ =
      pure (boundedResponse "grep" (WorkspaceGrepResponse {matches = reverse accumulated}))
    collectMatches regex (relative : rest) accumulated responseBytes = do
      let absolute = (.root) scope </> relative
      size <- getFileSize absolute
      if size > fromIntegral maxSearchFileBytes
        then collectMatches regex rest accumulated responseBytes
        else do
          bytes <- BS.readFile absolute
          if isBinary bytes
            then collectMatches regex rest accumulated responseBytes
            else case TE.decodeUtf8' bytes of
              Left _ -> collectMatches regex rest accumulated responseBytes
              Right contents ->
                case appendLineMatches regex relative (Text.lines contents) accumulated responseBytes of
                  Left err -> pure (Left err)
                  Right (nextMatches, nextBytes) -> collectMatches regex rest nextMatches nextBytes

appendLineMatches :: Regex -> FilePath -> [Text] -> [WorkspaceGrepMatch] -> Int -> Either WorkspaceError ([WorkspaceGrepMatch], Int)
appendLineMatches regex relative lines' existing responseBytes =
  foldM add (existing, responseBytes) (zip [1 ..] lines')
  where
    add state@(_matches, _bytes) (_lineNumber, lineText)
      | not (matchTest regex (Text.unpack lineText)) = Right state
    add (matches, bytes) (lineNumber, lineText)
      | length matches >= maxSearchMatches =
          Left (WorkspaceLimitExceeded ("search exceeds " <> tshow maxSearchMatches <> " matches"))
      | bytes + addedBytes > maxResponseBytes =
          Left (WorkspaceLimitExceeded ("search response exceeds " <> tshow maxResponseBytes <> " bytes"))
      | otherwise =
          Right
            ( WorkspaceGrepMatch
                { file = Text.pack relative,
                  line = lineNumber,
                  text = lineText
                }
                : matches,
              bytes + addedBytes
            )
      where
        addedBytes = BS.length (TE.encodeUtf8 (Text.pack relative <> lineText)) + 32

globWorkspace :: WorkspaceScope -> Text -> Maybe FilePath -> IO (Either WorkspaceError WorkspaceGlobResponse)
globWorkspace scope patternText requestedRoot = do
  walked <- walkWorkspace scope requestedRoot
  pure do
    paths <- walked
    let matched = filter (globMatches patternText . Text.pack) paths
    if length matched > maxGlobResults
      then Left (WorkspaceLimitExceeded ("glob exceeds " <> tshow maxGlobResults <> " results"))
      else
        let resultBytes = sum (BS.length . TE.encodeUtf8 . Text.pack <$> matched)
         in if resultBytes > maxResponseBytes
              then Left (WorkspaceLimitExceeded ("glob response exceeds " <> tshow maxResponseBytes <> " bytes"))
              else boundedResponse "glob" (WorkspaceGlobResponse {paths = Text.pack <$> matched})

walkWorkspace :: WorkspaceScope -> Maybe FilePath -> IO (Either WorkspaceError [FilePath])
walkWorkspace scope requestedRoot = do
  rootResult <- case requestedRoot of
    Nothing -> pure (Right ((.root) scope))
    Just raw -> do
      resolved <- resolveExistingPath scope True raw
      pure resolved
  case rootResult of
    Left err -> pure (Left err)
    Right absoluteRoot -> do
      directory <- doesDirectoryExist absoluteRoot
      if not directory
        then pure (Left (WorkspaceNotADirectory (maybe "." id requestedRoot)))
        else fmap (fmap snd) (go 0 0 absoluteRoot)
  where
    go depth seen directory
      | depth > maxTraversalDepth =
          pure (Left (WorkspaceLimitExceeded ("traversal exceeds depth " <> tshow maxTraversalDepth)))
      | otherwise = do
          names <- sort <$> listDirectory directory
          foldM (visit depth directory) (Right (seen, [])) names

    visit _ _ (Left err) _ = pure (Left err)
    visit depth directory (Right (seen, files)) name
      | name `elem` excludedNames = pure (Right (seen, files))
      | otherwise = do
          let child = directory </> name
          symlink <- pathIsSymbolicLink child
          if symlink
            then pure (Right (seen, files))
            else do
              isDirectory <- doesDirectoryExist child
              if isDirectory
                then do
                  nested <- go (depth + 1) seen child
                  pure do
                    (seen', nestedFiles) <- nested
                    Right (seen', files <> nestedFiles)
                else do
                  isFile <- doesFileExist child
                  if not isFile
                    then pure (Right (seen, files))
                    else
                      if seen >= maxVisitedFiles
                        then
                          pure
                            ( Left
                                (WorkspaceLimitExceeded ("traversal exceeds " <> tshow maxVisitedFiles <> " files"))
                            )
                        else
                          pure
                            ( Right
                                ( seen + 1,
                                  files <> [makeRelative ((.root) scope) child]
                                )
                            )

compileRegex :: Text -> Bool -> Maybe Regex
compileRegex patternText ignoreCase =
  makeRegexOptsM
    defaultCompOpt {caseSensitive = not ignoreCase}
    defaultExecOpt
    (Text.unpack patternText)

globMatches :: Text -> Text -> Bool
globMatches patternText candidate =
  Text.unpack subject =~ ("^" <> Text.unpack (globToRegex patternText) <> "$" :: String)
  where
    subject
      | "/" `Text.isInfixOf` patternText = candidate
      | otherwise = Text.pack (takeFileName (Text.unpack candidate))

globToRegex :: Text -> Text
globToRegex = go . Text.unpack
  where
    go [] = ""
    go ('*' : '*' : '/' : rest) = "(.*/)?" <> go rest
    go ('*' : '*' : rest) = ".*" <> go rest
    go ('*' : rest) = "[^/]*" <> go rest
    go ('?' : rest) = "[^/]" <> go rest
    go (character : rest) = Text.pack (escapeRegex character) <> go rest

escapeRegex :: Char -> String
escapeRegex character
  | isAlphaNum character || character `elem` ("/_-" :: String) = [character]
  | otherwise = ['\\', character]

resolveExistingPath :: WorkspaceScope -> Bool -> FilePath -> IO (Either WorkspaceError FilePath)
resolveExistingPath WorkspaceScope {root} allowRoot raw =
  case validateRelative allowRoot raw of
    Left err -> pure (Left err)
    Right components -> do
      symlink <- firstSymlink root components
      case symlink of
        Just path -> pure (Left (WorkspaceSymlinkRefused path))
        Nothing -> do
          let candidate = foldl (</>) root components
          exists <- (||) <$> doesFileExist candidate <*> doesDirectoryExist candidate
          if not exists
            then pure (Left (InvalidWorkspacePath raw))
            else do
              canonical <- canonicalizePath candidate
              if containedBy root canonical
                then pure (Right canonical)
                else pure (Left (WorkspacePathEscapes raw))

validateRelative :: Bool -> FilePath -> Either WorkspaceError [FilePath]
validateRelative allowRoot raw
  | '\NUL' `elem` raw = Left (InvalidWorkspacePath raw)
  | '\\' `elem` raw = Left (InvalidWorkspacePath raw)
  | isAbsolute raw = Left (WorkspacePathEscapes raw)
  | (null raw || raw == ".") && allowRoot = Right []
  | null raw = Left (InvalidWorkspacePath raw)
  | any invalidComponent components = Left (InvalidWorkspacePath raw)
  | any (`elem` excludedNames) components = Left (WorkspaceExcludedPath raw)
  | otherwise = Right components
  where
    components = Text.unpack <$> Text.splitOn "/" (Text.pack raw)
    invalidComponent component = null component || component == "." || component == ".."

firstSymlink :: FilePath -> [FilePath] -> IO (Maybe FilePath)
firstSymlink = go
  where
    go _ [] = pure Nothing
    go parent (component : rest) = do
      let child = parent </> component
      symlink <- pathIsSymbolicLink child
      if symlink then pure (Just child) else go child rest

containedBy :: FilePath -> FilePath -> Bool
containedBy parent candidate =
  let relative = makeRelative parent candidate
   in not (isAbsolute relative)
        && relative /= ".."
        && case splitDirectories relative of
          ".." : _ -> False
          _ -> True

validateScopeStillPresent :: WorkspaceScope -> IO (Either WorkspaceError ())
validateScopeStillPresent WorkspaceScope {root} = do
  exists <- doesDirectoryExist root
  if not exists
    then pure (Left (WorkspaceNotFound root))
    else do
      symlink <- pathIsSymbolicLink root
      if symlink
        then pure (Left (WorkspaceSymlinkRefused root))
        else do
          canonical <- canonicalizePath root
          pure
            ( if canonical == root
                then Right ()
                else Left (WorkspacePathEscapes root)
            )

isBinary :: ByteString -> Bool
isBinary = BS.elem 0 . BS.take 8192

boundedResponse :: (ToJSON value) => Text -> value -> Either WorkspaceError value
boundedResponse label value
  | LBS.length (Aeson.encode value) > fromIntegral maxResponseBytes =
      Left (WorkspaceLimitExceeded (label <> " response exceeds " <> tshow maxResponseBytes <> " bytes"))
  | otherwise = Right value

trimLine :: String -> String
trimLine = reverse . dropWhile (`elem` ['\n', '\r']) . reverse

tshow :: (Show value) => value -> Text
tshow = Text.pack . show

excludedNames :: [FilePath]
excludedNames = [".git", ".hg", ".svn", "dist-newstyle", ".stack-work", "node_modules", ".direnv"]

maxReadBytes :: Int
maxReadBytes = 256 * 1024

maxSearchFileBytes :: Int
maxSearchFileBytes = 1024 * 1024

maxVisitedFiles :: Int
maxVisitedFiles = 2000

maxTraversalDepth :: Int
maxTraversalDepth = 16

maxSearchMatches :: Int
maxSearchMatches = 100

maxGlobResults :: Int
maxGlobResults = 500

maxResponseBytes :: Int
maxResponseBytes = 128 * 1024
