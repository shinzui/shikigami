-- | Where a local-operator run works in a repository.
--
-- Under 'SeparateWorktree' a run gets its own Git worktree on a run branch,
-- both derived from the run and the repository, so one run may hold a
-- worktree in each of several repositories and reopening returns the same
-- one. A branch at another commit or a root on another branch is refused,
-- never reset. Under 'InPlace' the run works in the checkout on its current
-- branch: the tree must be clean, @HEAD@ must not be detached, and an
-- exclusive lock keeps a second run out until the first releases it.
module Shikigami.Workspace.Local.Worktree
  ( RunWorktree (..),
    WorktreeError (..),
    renderWorktreeError,
    openRunWorktree,
    releaseRunWorktree,
    worktreeOpenedEntry,
    gitIn,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (object, (.=))
import Data.Bifunctor (first)
import Data.Char (isAlphaNum, isHexDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Workflow (WorkflowId (..))
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Record (RecordEntry, mkRecordEntry, mkRecordKind, recordErrorText)
import Shikigami.Repository (RepositoryId, repositoryIdText)
import Shikigami.Trust.LocalOperator.Approvals (LocalRepository, WorkspacePlacement (..))
import Shikigami.Workspace.Launch (WorktreeRoot, worktreeRoot, worktreeRootPath)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (WriteMode), hPutStr, withFile)
import System.Posix.Files (fileExist)
import System.Posix.IO (OpenFileFlags (..), OpenMode (WriteOnly), closeFd, defaultFileFlags, openFd)
import System.Process (readProcessWithExitCode)

-- | Where one run works in one repository.
data RunWorktree = RunWorktree
  { repository :: !RepositoryId,
    source :: !FilePath,
    root :: !WorktreeRoot,
    branch :: !Text,
    -- | The commit the run started from: the undo point.
    base :: !Text,
    placement :: !WorkspacePlacement,
    suffix :: !Text
  }
  deriving stock (Eq, Show)

data WorktreeError
  = BaseUnresolvable !Text
  | BranchNameInvalid !Text
  | WorktreeConflict !Text
  | CheckoutDirty
  | DetachedHead
  | CheckoutLocked !Text
  | GitFailed !Text
  deriving stock (Eq, Show)

renderWorktreeError :: WorktreeError -> Text
renderWorktreeError = \case
  BaseUnresolvable detail -> "the approved base does not name a commit: " <> detail
  BranchNameInvalid branch -> "the run branch name is not valid: " <> branch
  WorktreeConflict detail -> "the run worktree conflicts with existing state (it is never reset): " <> detail
  CheckoutDirty -> "the checkout has uncommitted changes; an in-place run needs a clean tree"
  DetachedHead -> "the checkout's HEAD is detached; an in-place run needs a current branch"
  CheckoutLocked run -> "another run (" <> run <> ") holds this checkout"
  GitFailed detail -> "git failed: " <> Text.take 256 detail

-- | Open (or reopen) the place a run works in a repository.
openRunWorktree :: FilePath -> AgentName -> WorkflowId -> LocalRepository -> IO (Either WorktreeError RunWorktree)
openRunWorktree stateDirectory agent runId repository = case repository.placement of
  SeparateWorktree -> openSeparate
  InPlace -> openInPlace
  where
    suffix = Text.take 12 (Text.filter isHexDigit (Text.drop 7 (versionedDigest "shikigami.local-worktree/1" (runId.unWorkflowId, repositoryIdText repository.identity))))
    directoryName = Text.unpack (Text.map (\c -> if isAlphaNum c then c else '-') (stripScheme (repositoryIdText repository.identity)))
    stripScheme = Text.dropWhile (== '-') . snd . Text.breakOnEnd "//"
    runBranch = "shikigami/" <> agentNameText agent <> "/" <> suffix
    rootPath = stateDirectory </> "worktrees" </> directoryName </> Text.unpack suffix

    openSeparate = do
      checked <- gitIn repository.source ["check-ref-format", "--branch", runBranch]
      commit <- gitIn repository.source ["rev-parse", "--verify", repository.base <> "^{commit}"]
      case (checked, commit) of
        (Left _, _) -> pure (Left (BranchNameInvalid runBranch))
        (_, Left detail) -> pure (Left (BaseUnresolvable detail))
        (Right _, Right baseCommit) -> do
          let worktree = RunWorktree {repository = repository.identity, source = repository.source, root = worktreeRoot rootPath, branch = runBranch, base = baseCommit, placement = SeparateWorktree, suffix}
          exists <- doesDirectoryExist rootPath
          if exists
            then
              gitIn rootPath ["symbolic-ref", "--short", "HEAD"] <&&> \case
                current
                  | current == runBranch -> do
                      -- Reopening: the worktree's base is where its branch started.
                      started <- gitIn repository.source ["merge-base", baseCommit, runBranch]
                      pure (first GitFailed started >>= \b -> Right worktree {base = b})
                  | otherwise -> pure (Left (WorktreeConflict (Text.pack rootPath <> " is on " <> current)))
            else
              gitIn repository.source ["rev-parse", "--verify", "--quiet", "refs/heads/" <> runBranch] >>= \case
                Right _ -> pure (Left (WorktreeConflict ("branch " <> runBranch <> " exists without its worktree")))
                Left _ -> do
                  createDirectoryIfMissing True (takeDirectory rootPath)
                  added <- gitIn repository.source ["worktree", "add", "--quiet", "-b", runBranch, Text.pack rootPath, baseCommit]
                  pure (first GitFailed added >> Right worktree)

    openInPlace = do
      status <- gitIn repository.source ["status", "--porcelain"]
      current <- gitIn repository.source ["symbolic-ref", "--short", "HEAD"]
      commit <- gitIn repository.source ["rev-parse", "--verify", "HEAD^{commit}"]
      case (status, current, commit) of
        (Left detail, _, _) -> pure (Left (GitFailed detail))
        (Right porcelain, _, _) | not (Text.null porcelain) -> pure (Left CheckoutDirty)
        (_, Left _, _) -> pure (Left DetachedHead)
        (_, _, Left detail) -> pure (Left (BaseUnresolvable detail))
        (Right _, Right branchName, Right headCommit) ->
          acquireLock (lockPath stateDirectory directoryName) runId >>= \case
            Left holder -> pure (Left (CheckoutLocked holder))
            Right () ->
              pure (Right RunWorktree {repository = repository.identity, source = repository.source, root = worktreeRoot repository.source, branch = branchName, base = headCommit, placement = InPlace, suffix})

    action <&&> continue = action >>= either (pure . Left . GitFailed) continue

-- | Release an in-place run's lock. A separate worktree holds no lock.
releaseRunWorktree :: FilePath -> WorkflowId -> RunWorktree -> IO ()
releaseRunWorktree stateDirectory runId RunWorktree {placement, repository}
  | placement /= InPlace = pure ()
  | otherwise = do
      let path = lockPath stateDirectory (Text.unpack (Text.map (\c -> if isAlphaNum c then c else '-') (snd (Text.breakOnEnd "//" (repositoryIdText repository)))))
      holder <- try @IOException (readFile path)
      case holder of
        Right contents | Text.strip (Text.pack contents) == runId.unWorkflowId -> removeFile path
        _ -> pure ()

lockPath :: FilePath -> FilePath -> FilePath
lockPath stateDirectory name = stateDirectory </> "locks" </> (name <> ".lock")

-- | Create the lock exclusively, or accept it when this run already holds it.
acquireLock :: FilePath -> WorkflowId -> IO (Either Text ())
acquireLock path runId = do
  createDirectoryIfMissing True (takeDirectory path)
  created <- try (openFd path WriteOnly defaultFileFlags {exclusive = True, creat = Just 0o600})
  case created of
    Right fd -> do
      closeFd fd
      withFile path WriteMode (`hPutStr` Text.unpack runId.unWorkflowId)
      pure (Right ())
    Left (_ :: IOException) -> do
      exists <- fileExist path
      holder <- if exists then Text.strip . Text.pack <$> readFile path else pure "unknown"
      pure (if holder == runId.unWorkflowId then Right () else Left holder)

-- | The @workspace.opened@ record entry: the repository, the placement, the
-- root, the branch and the base commit (the documented undo point).
worktreeOpenedEntry :: RunWorktree -> Either Text RecordEntry
worktreeOpenedEntry RunWorktree {repository, root, branch, base, placement} = do
  kind <- mkRecordKind "workspace.opened"
  first recordErrorText $
    mkRecordEntry
      kind
      ( object
          [ "repository" .= repositoryIdText repository,
            "placement" .= placement,
            "root" .= worktreeRootPath root,
            "branch" .= branch,
            "base" .= base
          ]
      )

-- | Run @git -C directory args@ and return trimmed standard output.
gitIn :: FilePath -> [Text] -> IO (Either Text Text)
gitIn directory arguments = do
  result <- try (readProcessWithExitCode "git" ("-C" : directory : (Text.unpack <$> arguments)) "")
  pure case result of
    Left (problem :: IOException) -> Left (Text.pack (show problem))
    Right (ExitSuccess, out, _) -> Right (Text.strip (Text.pack out))
    Right (_, _, err) -> Left (Text.strip (Text.pack err))
