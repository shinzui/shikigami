module Shikigami.LocalHostSpec (tests) where

import Control.Exception (SomeException, try)
import Data.Text qualified as Text
import Data.Unique (hashUnique, newUnique)
import Keiro.Workflow (WorkflowId (..))
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Repository (repositoryId)
import Shikigami.Trust.LocalOperator.Approvals
import Shikigami.Workspace.Launch
import Shikigami.Workspace.Local.Launcher (hostProcessLauncher)
import Shikigami.Workspace.Local.Worktree
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removePathForcibly)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Signals (nullSignal, signalProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "local host"
    [ testCase "a command past its deadline is ended with its whole process group" $ withDirectory \root -> do
        sh <- maybe (assertFailure "no sh" >> undefined) pure =<< resolveProgram "sh"
        result <- hostProcessLauncher.launch (request sh root ["-c", "sleep 30 & echo $! > child; sleep 30"] 1 65536)
        case result of
          Right LaunchResult {outcome} -> outcome @?= DeadlineExpired
          Left refusal -> assertFailure (show refusal)
        child <- read <$> readFile (root </> "child")
        survived <- try @SomeException (signalProcess nullSignal child)
        assertBool "the detached descendant was killed with its group" (either (const True) (const False) survived),
      testCase "output beyond the bound is counted, not kept" $ withDirectory \root -> do
        sh <- maybe (assertFailure "no sh" >> undefined) pure =<< resolveProgram "sh"
        result <- hostProcessLauncher.launch (request sh root ["-c", "head -c 10485760 /dev/zero | tr '\\\\0' a"] 60 1024)
        case result of
          Right LaunchResult {outcome, stdout} -> do
            outcome @?= Exited ExitSuccess
            Text.length stdout.text @?= 1024
            stdout.dropped @?= 10485760 - 1024
          Left refusal -> assertFailure (show refusal),
      testCase "the environment is cleared except the base set and inherited names" $ withDirectory \root -> do
        sh <- maybe (assertFailure "no sh" >> undefined) pure =<< resolveProgram "sh"
        Right LaunchResult {stdout} <- hostProcessLauncher.launch (request sh root ["-c", "echo ${PGHOST:-absent}"] 10 1024)
        Text.strip stdout.text @?= "absent",
      testCase "a separate worktree is derived from the run and reopened, and a conflict is refused" $ withRepository \repo state -> do
        let repository = localRepo repo SeparateWorktree
        first' <- openRunWorktree state agent (WorkflowId "run-a") repository
        again <- openRunWorktree state agent (WorkflowId "run-a") repository
        other <- openRunWorktree state agent (WorkflowId "run-b") repository
        case (first', again, other) of
          (Right one, Right two, Right three) -> do
            two @?= one
            assertBool "the branch names the agent and run suffix" ("shikigami/local-maintainer/" `Text.isPrefixOf` one.branch)
            assertBool "another run gets another worktree" (three.root /= one.root)
          problem -> assertFailure (show problem)
        -- A root that moved to another branch is refused, never reset.
        Right opened <- pure first'
        _ <- gitIn (worktreeRootPath opened.root) ["checkout", "-q", "-b", "elsewhere"]
        openRunWorktree state agent (WorkflowId "run-a") repository >>= \case
          Left WorktreeConflict {} -> pure ()
          other' -> assertFailure ("expected a conflict, got " <> show other'),
      testCase "in place needs a clean tree and admits one run at a time" $ withRepository \repo state -> do
        let repository = localRepo repo InPlace
        Right held <- openRunWorktree state agent (WorkflowId "run-a") repository
        held.root @?= worktreeRoot repo
        openRunWorktree state agent (WorkflowId "run-a") repository >>= \case
          Right _ -> pure ()
          other -> assertFailure ("the holder may reopen: " <> show other)
        openRunWorktree state agent (WorkflowId "run-b") repository >>= \case
          Left CheckoutLocked {} -> pure ()
          other -> assertFailure ("expected a lock refusal, got " <> show other)
        releaseRunWorktree state (WorkflowId "run-a") held
        writeFile (repo </> "dirty.txt") "x"
        openRunWorktree state agent (WorkflowId "run-b") repository >>= (@?= Left CheckoutDirty)
    ]
  where
    request sh root arguments seconds bytes =
      LaunchRequest
        { program = sh,
          arguments,
          directory = worktreeRoot root,
          inherit = [],
          deadline = either (error . Text.unpack) id (mkLaunchDeadline seconds),
          outputLimit = either (error . Text.unpack) id (mkOutputLimit bytes)
        }

agent :: AgentName
agent = either (error . Text.unpack) id (mkAgentName "local-maintainer")

localRepo :: FilePath -> WorkspacePlacement -> LocalRepository
localRepo = testLocalRepository (repositoryId "mori://test/local-host") "HEAD"

withDirectory :: (FilePath -> IO a) -> IO a
withDirectory use = do
  temporary <- getTemporaryDirectory
  unique <- hashUnique <$> newUnique
  let root = temporary </> ("shikigami-local-host-spec-" <> show unique)
  removePathForcibly root
  createDirectoryIfMissing True root
  result <- use root
  removePathForcibly root
  pure result

withRepository :: (FilePath -> FilePath -> IO a) -> IO a
withRepository use = withDirectory \root -> do
  let repo = root </> "repo"
      state = root </> "state"
  createDirectoryIfMissing True repo
  mapM_
    (\arguments -> gitIn repo arguments >>= either (assertFailure . Text.unpack) (const (pure ())))
    [["init", "-q", "-b", "main"], ["config", "user.email", "test@example.invalid"], ["config", "user.name", "Test"], ["commit", "-q", "--allow-empty", "-m", "initial"]]
  use repo state
