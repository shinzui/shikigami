module Shikigami.WorkspaceStoreSpec (tests, withFixture, commitRepository) where

import Control.Concurrent.Async (async, cancel, concurrently)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Data.ByteString qualified as Bytes
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Hasql.Transaction (Transaction)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Principal (AgentIdentity (..))
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Execution.Identity (ExecutionRootId (..))
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Prelude ((&), (.~))
import Shikigami.WorkerSession.Types (AssignmentId (..), WorkerSessionId (..))
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.InstructionLoader
import Shikigami.Workspace.Instructions (InstructionError (..), RepositoryInstruction (..), bundleDigest, bundleFiles, instructionsForPath)
import Shikigami.Workspace.Instructions qualified as Instructions
import Shikigami.Workspace.Store
import Shikigami.Workspace.Types
import System.Directory
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace store and allocation"
    [ testCase "concurrent reservation and lost response recover one immutable binding" $ withFixture fixture \env source root repo -> do
        (a, b) <- concurrently (run env (reserveWorkspaceTx root request repo)) (run env (reserveWorkspaceTx root request repo))
        first <- right a
        b @?= Right first
        let binding = fst first
        fmap fst <$> run env (reserveWorkspaceTx root request repo) >>= (@?= Right binding)
        before <- sourceSnapshot source
        (x, y) <- concurrently (allocateWorkspace root binding Reserved) (allocateWorkspace root binding Reserved)
        x @?= Right ()
        y @?= Right ()
        -- Crash after publication, before ready acknowledgement: preserve edits.
        writeFile (workspaceFiles root binding </> "dependency.txt") "accepted change\n"
        allocateWorkspace root binding Reserved >>= (@?= Right ())
        readFile (workspaceFiles root binding </> "dependency.txt") >>= (@?= "accepted change\n")
        run env (markWorkspaceReadyTx binding) >>= (@?= Right ())
        run env (reserveWorkspaceTx root request repo) >>= (@?= Right (binding, Ready))
        sourceSnapshot source >>= (@?= before)
        allocateWorkspace (root <> "-other") binding Reserved >>= (@?= Left WorkspaceAllocationRefused),
      testCase "changed run, owner, epoch, root, policy or source cannot rebind an assignment" $ withFixture fixture \env _ root repo -> do
        _ <- right =<< run env (reserveWorkspaceTx root request repo)
        mapM_
          (\changed -> run env (reserveWorkspaceTx root changed repo) >>= (@?= Left WorkspaceBindingConflict))
          [request & #runId .~ "different", request & #owner .~ CompatibilityIdentity "other", request & #epoch .~ 1, request & #rootId .~ ExecutionRootId "other"]
        changed <- resolved (repositorySource repo) (repositoryBase repo) "policy-2"
        run env (reserveWorkspaceTx root request changed) >>= (@?= Left WorkspaceBindingConflict)
        changedSource <- resolved (repositorySource repo <> "-other") (repositoryBase repo) "policy-1"
        run env (reserveWorkspaceTx root request changedSource) >>= (@?= Left WorkspaceBindingConflict)
        changedBase <- resolved (repositorySource repo) (Text.replicate 40 "a") "policy-1"
        run env (reserveWorkspaceTx root request changedBase) >>= (@?= Left WorkspaceBindingConflict)
        run env (reserveWorkspaceTx (root <> "-other") request repo) >>= (@?= Left WorkspaceBindingConflict),
      testCase "distinct assignments have private files, objects and indexes" $ withFixture fixture \env source root repo -> do
        (one, _) <- right =<< run env (reserveWorkspaceTx root request repo)
        (two, _) <- right =<< run env (reserveWorkspaceTx root ((request & #assignment .~ (Just (WorkerSessionId "session", AssignmentId "two")))) repo)
        assertBool "different resources" (one.workspace /= two.workspace)
        before <- sourceSnapshot source
        allocateWorkspace root one Reserved >>= (@?= Right ())
        allocateWorkspace root two Reserved >>= (@?= Right ())
        writeFile (workspaceFiles root one </> "dependency.txt") "new dependency\n"
        _ <- git ["--git-dir=" <> workspaceMetadata root one, "--work-tree=" <> workspaceFiles root one, "add", "dependency.txt"]
        readFile (workspaceFiles root two </> "dependency.txt") >>= (@?= "old dependency\n")
        oneIndex <- Bytes.readFile (workspaceMetadata root one </> "index")
        twoIndex <- Bytes.readFile (workspaceMetadata root two </> "index")
        assertBool "indexes differ after staging in one" (oneIndex /= twoIndex)
        doesPathExist (workspaceFiles root one </> ".git") >>= (@?= False)
        sourceSnapshot source >>= (@?= before),
      testCase "instructions are loaded from the admitted tree after worktree policy edits" $ withFixture fixture \env source root _ -> do
        writeFile (source </> "AGENTS.md") "PRIVATE_ROOT: validate first\n"
        createDirectory (source </> "src")
        writeFile (source </> "src" </> "AGENTS.md") "PRIVATE_NESTED: use scoped checks\n"
        writeFile (source </> "README.md") "ordinary source is not an instruction"
        repo <- commitRepository source
        (binding, _) <- right =<< run env (reserveWorkspaceTx root request repo)
        allocateWorkspace root binding Reserved >>= (@?= Right ())
        bundle <- right =<< loadRepositoryInstructions binding 65536
        map (.path) (bundleFiles bundle) @?= ["AGENTS.md", "src/AGENTS.md"]
        admission <- right =<< loadWorkspaceAdmission binding "execution-assignment" 65536
        admission.bindingDigest @?= workspaceBindingDigest binding
        admission.owner @?= binding.request.owner
        admission.instructions @?= bundle
        admission.filePolicy @?= Just Instructions.nativeFilePolicy
        fmap (map (.text)) (instructionsForPath bundle "src/new.hs") @?= Right ["PRIVATE_ROOT: validate first\n", "PRIVATE_NESTED: use scoped checks\n"]
        writeFile (workspaceFiles root binding </> "AGENTS.md") "changed policy must not take effect"
        loadRepositoryInstructions binding 65536 >>= (@?= Right bundle)
        loadRepositoryInstructions binding 4 >>= (@?= Left InstructionBudgetExceeded)
        -- Only an explicitly approved new base and a new assignment admit the
        -- next policy identity. The old private repository retains its bundle.
        writeFile (source </> "AGENTS.md") "PRIVATE_NEW_ROOT_POLICY"
        nextRepository <- commitRepository source
        (nextBinding, _) <- right =<< run env (reserveWorkspaceTx root ((request & #assignment .~ (Just (WorkerSessionId "session", AssignmentId "next")))) nextRepository)
        allocateWorkspace root nextBinding Reserved >>= (@?= Right ())
        nextBundle <- right =<< loadRepositoryInstructions nextBinding 65536
        assertBool "new assignment admits next instruction identity" (bundleDigest nextBundle /= bundleDigest bundle)
        fmap (map (.text)) (instructionsForPath nextBundle "test/new.hs") @?= Right ["PRIVATE_NEW_ROOT_POLICY"]
        loadRepositoryInstructions binding 65536 >>= (@?= Right bundle),
      testCase "case-colliding base paths refuse instruction admission on every host" $ withFixture fixture \env source root repo -> do
        blob <- Text.strip . Text.pack <$> git ["-C", source, "rev-parse", "HEAD:dependency.txt"]
        tree <- Text.strip . Text.pack <$> gitInput ["-C", source, "mktree"] ("100644 blob " <> Text.unpack blob <> "\tSRC.txt\n100644 blob " <> Text.unpack blob <> "\tsrc.txt\n")
        base <- Text.strip . Text.pack <$> git ["-C", source, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit-tree", Text.unpack tree, "-m", "case-collision"]
        _ <- git ["-C", source, "update-ref", "refs/heads/case-fixture", Text.unpack base]
        selected <- resolved source base "policy-1"
        (binding, _) <- right =<< run env (reserveWorkspaceTx root request selected)
        createDirectoryIfMissing True (takeDirectoryOfFiles root binding)
        _ <- git ["clone", "--bare", "--no-hardlinks", "--", source, workspaceMetadata root binding]
        loadRepositoryInstructions binding 65536 >>= (@?= Left InstructionSourceRefused)
        repositoryIdentity repo @?= "mori://fixture/repo",
      testCase "symlink instruction files fail admission without following their targets" $ withFixture fixture \env source root _ -> do
        createFileLink "dependency.txt" (source </> "AGENTS.md")
        repo <- commitRepository source
        (binding, _) <- right =<< run env (reserveWorkspaceTx root request repo)
        allocateWorkspace root binding Reserved >>= (@?= Right ())
        loadRepositoryInstructions binding 65536 >>= (@?= Left InstructionSourceRefused),
      testCase "native file qualification refuses Unicode aliases while instruction snapshots stay readable" $ withFixture fixture \env source root _ -> do
        writeFile (source </> "caf\233.txt") "ordinary UTF-8 content"
        writeFile (source </> "AGENTS.md") "root policy"
        repo <- commitRepository source
        (binding, _) <- right =<< run env (reserveWorkspaceTx root request repo)
        allocateWorkspace root binding Reserved >>= (@?= Right ())
        bundle <- right =<< loadRepositoryInstructions binding 65536
        map (.text) (bundleFiles bundle) @?= ["root policy"]
        loadWorkspaceAdmission binding "native-files" 65536 >>= (@?= Left InstructionSourceRefused),
      testCase "borrowed source objects are copied into the private repository" $ withFixture fixture \env source root original -> do
        let borrowed = source <> "-borrowed"
        _ <- git ["clone", "--shared", "--", source, borrowed]
        repo <- resolved borrowed (repositoryBase original) "policy-1"
        (binding, _) <- right =<< run env (reserveWorkspaceTx root request repo)
        allocateWorkspace root binding Reserved >>= (@?= Right ())
        doesFileExist (workspaceMetadata root binding </> "objects" </> "info" </> "alternates") >>= (@?= False)
        renameDirectory source (source <> "-unavailable")
        git ["--git-dir=" <> workspaceMetadata root binding, "cat-file", "-t", Text.unpack (repositoryBase original)] >>= (@?= "commit\n"),
      testCase "interrupted staging cannot become a published workspace" $ withFixture fixture \env _ root repo -> do
        (binding, _) <- right =<< run env (reserveWorkspaceTx root request repo)
        reached <- newEmptyMVar
        block <- newEmptyMVar
        worker <- async (allocateWorkspaceWithCheckpoint (putMVar reached () >> takeMVar block) root binding Reserved)
        takeMVar reached
        cancel worker
        doesPathExist (takeDirectoryOfFiles root binding) >>= (@?= False)
        run env (inspectWorkspaceTx binding.workspace) >>= (@?= Just (binding, Reserved))
        allocateWorkspace root binding Reserved >>= (@?= Right ())
        run env (markWorkspaceReadyTx binding) >>= (@?= Right ())
        removeDirectoryRecursive (takeDirectoryOfFiles root binding)
        allocateWorkspace root binding Ready >>= (@?= Left WorkspaceAllocationRefused),
      testCase "approved non-commit object refuses allocation" $ withFixture fixture \env source root _ -> do
        blob <- Text.strip . Text.pack <$> git ["-C", source, "rev-parse", "HEAD:dependency.txt"]
        repo <- resolved source blob "policy-1"
        (binding, _) <- right =<< run env (reserveWorkspaceTx root request repo)
        allocateWorkspace root binding Reserved >>= (@?= Left WorkspaceAllocationRefused)
        run env (inspectWorkspaceTx binding.workspace) >>= (@?= Just (binding, Reserved)),
      testCase "destination substitution and invalid request refuse" $ withFixture fixture \env _ root repo -> do
        run env (reserveWorkspaceTx root ((request & #principal .~ (UnresolvedLegacyIdentity))) repo) >>= (@?= Left InvalidWorkspaceRequest)
        (binding, _) <- right =<< run env (reserveWorkspaceTx root request repo)
        createDirectory root
        createDirectory (root </> "elsewhere")
        createDirectoryLink (root </> "elsewhere") (takeDirectoryOfFiles root binding)
        allocateWorkspace root binding Reserved >>= (@?= Left WorkspaceAllocationRefused)
    ]
  where
    takeDirectoryOfFiles root binding = takeDirectory (workspaceFiles root binding)

request :: WorkspaceRequest
request = WorkspaceRequest "run" (Just (WorkerSessionId "session", AssignmentId "one")) (ExecutionRootId "root") (CompatibilityIdentity "parent") (CompatibilityIdentity "worker") 0

resolved :: FilePath -> Text.Text -> Text.Text -> IO ResolvedRepository
resolved source base policy = do
  catalog <- right (mkWorkspaceCatalog [RepositoryPolicy "mori://fixture/repo" source [base] base policy])
  right (resolveRepository catalog "mori://fixture/repo" Nothing)

withFixture :: DatabaseFixture -> (AppEnv -> FilePath -> FilePath -> ResolvedRepository -> IO a) -> IO a
withFixture fixture use = withShikigamiFreshDatabase fixture \connection -> bracket temporary removeDirectoryRecursive \dir -> do
  tracer <- noopTracer
  let env = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}
      source = dir </> "source"
      root = dir </> "workspaces"
  createDirectory source
  _ <- git ["init", source]
  writeFile (source </> "dependency.txt") "old dependency\n"
  _ <- git ["-C", source, "add", "dependency.txt"]
  _ <- git ["-C", source, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "base"]
  base <- Text.strip . Text.pack <$> git ["-C", source, "rev-parse", "HEAD"]
  repo <- resolved source base "policy-1"
  use env source root repo
  where
    temporary = do
      parent <- getTemporaryDirectory >>= canonicalizePath
      nonce <- UUID.toString <$> UUID.nextRandom
      let dir = parent </> ("shikigami-workspace-" <> nonce)
      createDirectory dir
      pure dir

run :: AppEnv -> Transaction a -> IO a
run env transaction = runAppIO env (runTransaction transaction) >>= right

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

-- Snapshot every source file, including Git metadata, so source-state writes fail
-- the fixture even when status and HEAD appear unchanged.
sourceSnapshot :: FilePath -> IO [(FilePath, Bytes.ByteString, Permissions, UTCTime)]
sourceSnapshot root = do
  entries <- listDirectory root
  concat
    <$> mapM
      ( \entry -> do
          let path = root </> entry
          directory <- doesDirectoryExist path
          if directory
            then sourceSnapshot path
            else do
              bytes <- Bytes.readFile path
              permissions <- getPermissions path
              modified <- getModificationTime path
              pure [(path, bytes, permissions, modified)]
      )
      (sort entries)

git :: [String] -> IO String
git args = gitInput args ""

gitInput :: [String] -> String -> IO String
gitInput args input = do
  (status, output, _) <- readCreateProcessWithExitCode ((proc "git" (["-c", "core.hooksPath=/dev/null"] <> args)) {env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent"), ("GIT_CONFIG_NOSYSTEM", "1"), ("GIT_CONFIG_GLOBAL", "/dev/null")]}) input
  status @?= ExitSuccess
  pure output

commitRepository :: FilePath -> IO ResolvedRepository
commitRepository source = do
  _ <- git ["-C", source, "add", "."]
  _ <- git ["-C", source, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "instructions"]
  base <- Text.strip . Text.pack <$> git ["-C", source, "rev-parse", "HEAD"]
  resolved source base "policy-1"
