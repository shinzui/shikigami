module Shikigami.LocalHostSpec (tests) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Unique (hashUnique, newUnique)
import Keiro.Workflow (WorkflowId (..))
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Agent.DeclarationValue (agentEnablement, declarationCoordinate)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Authority (allowAllForTests)
import Shikigami.Record (memoryRecord, unspecifiedTier)
import Shikigami.Repository (repositoryId)
import Shikigami.Trust.LocalOperator.Approvals
import Shikigami.Trust.LocalOperator.Grant (Interaction (..), openGrantStore, resolveGrant)
import Shikigami.Workspace.Launch
import Shikigami.Workspace.Local.Adapters (LocalWorkspace (..), editTool, gitTool)
import Shikigami.Workspace.Local.Launcher (hostProcessLauncher)
import Shikigami.Workspace.Local.Worktree
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removePathForcibly)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (createSymbolicLink)
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
      testCase "one run holds a separate worktree in each of two repositories" $ withRepository \repoA state -> withRepository \repoB _ -> do
        Right inA <- openRunWorktree state agent (WorkflowId "run-a") (testLocalRepository (repositoryId "mori://test/a") "HEAD" repoA SeparateWorktree)
        Right inB <- openRunWorktree state agent (WorkflowId "run-a") (testLocalRepository (repositoryId "mori://test/b") "HEAD" repoB SeparateWorktree)
        assertBool "two roots" (inA.root /= inB.root)
        assertBool "suffixes differ by repository" (inA.suffix /= inB.suffix),
      testCase "replace applies, replays idempotently and refuses unsafe paths and stale reads" $ withRepository \repo state -> do
        local <- fixtureWorkspace repo state
        Right worktree <- openRunWorktree state agent (WorkflowId "run-a") (localRepo repo SeparateWorktree)
        let call tool input = editTool local (WorkflowId "run-a") worktree tool input
            replace path expected content = call "replace" (object ["path" .= (path :: Text), "expected" .= (expected :: Text), "content" .= (content :: Text)])
        Right created <- replace "docs/NOTES.md" "" "first\n"
        field "changed" created @?= Just (Bool True)
        Right replayed <- replace "docs/NOTES.md" "" "first\n"
        field "changed" replayed @?= Just (Bool False)
        stale <- replace "docs/NOTES.md" "" "second\n"
        assertBool "a stale expected digest is refused" (isLeft' stale)
        Right readBack <- call "read" (object ["path" .= ("docs/NOTES.md" :: Text)])
        Just (String digest) <- pure (field "contentDigest" readBack)
        Right _ <- replace "docs/NOTES.md" digest "second\n"
        mapM_
          (\path -> replace path "" "x" >>= assertBool ("refused: " <> Text.unpack path) . isLeft')
          ["../outside", "/etc/passwd", ".git/config", "a/../../b"]
        createSymbolicLink "/tmp" (worktreeRootPath worktree.root </> "linked")
        replace "linked/escape.txt" "" "x" >>= assertBool "a symbolic link is refused" . isLeft',
      testCase "commit refuses a stale parent and records the run in its trailers" $ withRepository \repo state -> do
        local <- fixtureWorkspace repo state
        Right worktree <- openRunWorktree state agent (WorkflowId "run-a") (localRepo repo SeparateWorktree)
        let git' tool input = gitTool local (WorkflowId "run-a") worktree tool input
        Right _ <- editTool local (WorkflowId "run-a") worktree "replace" (object ["path" .= ("README.md" :: Text), "expected" .= ("" :: Text), "content" .= ("hello\n" :: Text)])
        Right status <- git' "status" (object [])
        Just (String parent) <- pure (field "head" status)
        stale <- git' "commit" (object ["message" .= ("docs: add readme" :: Text), "expectedParent" .= ("0000000" :: Text)])
        assertBool "a stale parent is refused" (isLeft' stale)
        Right committed <- git' "commit" (object ["message" .= ("docs: add readme" :: Text), "expectedParent" .= parent])
        Just (String commit) <- pure (field "commit" committed)
        Right trailers <- gitIn (worktreeRootPath worktree.root) ["log", "-1", "--format=%(trailers:key=Shikigami-Run,valueonly)", commit]
        trailers @?= "run-a"
        again <- git' "commit" (object ["message" .= ("docs: nothing" :: Text), "expectedParent" .= commit])
        assertBool "nothing to commit is refused" (isLeft' again),
      testCase "in place needs a clean tree and admits one run at a time" $ withRepository \repo state -> do
        let repository = localRepo repo InPlace
        Right held <- openRunWorktree state agent (WorkflowId "run-a") repository
        held.root @?= worktreeRoot repo
        writeFile (repo </> "edited-by-the-run.txt") "x"
        openRunWorktree state agent (WorkflowId "run-a") repository >>= \case
          Right reopened -> reopened.base @?= held.base
          other -> assertFailure ("the holder may reopen the tree it dirtied: " <> show other)
        openRunWorktree state agent (WorkflowId "run-b") repository >>= \case
          Left CheckoutLocked {} -> pure ()
          other -> assertFailure ("expected a lock refusal, got " <> show other)
        releaseRunWorktree state (WorkflowId "run-a") held
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

-- | An allow-all, in-memory-recorded workspace over a test repository.
fixtureWorkspace :: FilePath -> FilePath -> IO LocalWorkspace
fixtureWorkspace repo state = do
  (record, _) <- memoryRecord
  git <- maybe (assertFailure "no git" >> undefined) pure =<< resolveProgram "git"
  approvals <- either (fail . show) pure =<< pure (Right emptyApprovals :: Either String LocalApprovals)
  store <- either (fail . show) pure =<< openGrantStore state
  grant <- either (fail . show) pure =<< resolveGrant (Interactive (\_ -> pure True)) approvals store (\_ -> pure (Right ())) fixtureDecl (localRepo repo SeparateWorktree)
  pure
    LocalWorkspace
      { stateDirectory = state,
        agent,
        principal = declarationCoordinate "principal_local_maintainer",
        repository = localRepo repo SeparateWorktree,
        grant,
        authority = allowAllForTests,
        record,
        tier = unspecifiedTier,
        launcher = hostProcessLauncher,
        git
      }

fixtureDecl :: AgentDecl
fixtureDecl =
  AgentDecl
    { name = agent,
      description = "",
      trigger = Event {eventType = declarationCoordinate "local.maintenance.requested"},
      behavior = Skill {path = declarationCoordinate "agents/skills/local-maintainer"},
      sinks = [],
      delegates = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      tools = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = agentEnablement True,
      expertise = [],
      routing = Nothing
    }

field :: Text -> Value -> Maybe Value
field name = \case
  Object o -> KeyMap.lookup (Key.fromText name) o
  _ -> Nothing

isLeft' :: Either a b -> Bool
isLeft' = either (const True) (const False)

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
