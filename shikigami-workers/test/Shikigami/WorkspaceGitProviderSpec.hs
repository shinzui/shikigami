-- Accepted executor and real Git evidence. Only native host/tree enumeration
-- is instrumented; native coupled Git qualification remains a separate gate.
module Shikigami.WorkspaceGitProviderSpec (tests) where

import Control.Exception (throwIO)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Effectful (Eff)
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Kioku.App (AppEffects, AppEnv, runAppIO)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization
import Shikigami.Capability.Provider (DurableAdapter (..))
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Identity
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.Runner (DispatchContext (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude ((&), (.~))
import Shikigami.Store.ExecutionResources qualified as Roots
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.ContainedFile
import Shikigami.Workspace.FileProvider
import Shikigami.Workspace.Git (runWorkspaceGit)
import Shikigami.Workspace.GitCapture
import Shikigami.Workspace.GitObjects qualified as Objects
import Shikigami.Workspace.GitProvider
import Shikigami.Workspace.GitStore qualified as Git
import Shikigami.Workspace.GitTypes
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.ProcessProfileStore
import Shikigami.Workspace.ProcessStore qualified as Processes
import Shikigami.Workspace.Provider
import Shikigami.Workspace.Service (GitScan (..), scanGitReceipts)
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.Types
import Shikigami.WorkspaceFileProviderSpec qualified as Fixture
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace accepted Git provider"
    [ testCase "declared exact commit uses the accepted claim and duplicate delivery creates one commit" $ withGit fixture "commit" \env binding snapshot access reference runtime profile backend -> do
        profileReady env binding profile
        writes <- newIORef (0 :: Int)
        let counted = backend & #afterPublication .~ modifyIORef' writes (+ 1)
            executor = Fixture.executorForAdapter (workspaceGitAdapterWithBackend counted) runtime
        current <- Objects.readHead (workspaceMetadata binding.storageRoot binding) >>= right
        current @?= binding.base
        Bytes.writeFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") "new dependency\n"
        execute executor snapshot reference
        readIORef writes >>= (@?= 1)
        Just record <- run env (runTransaction (Git.inspectGitTx reference.operationId))
        record.phase @?= GitApplied
        record.attemptId @?= reference.attemptId
        Just candidate <- pure record.candidate
        candidate.paths @?= ["src/dependency.txt"]
        Objects.verifyPublishedCommit (workspaceMetadata binding.storageRoot binding) candidate >>= (@?= Right True)
        execute executor snapshot reference
        readIORef writes >>= (@?= 1)
        (_, state) <- right =<< run env (Execution.loadExecution access)
        state.cursor @?= 2
        source <- right =<< runWorkspaceGit binding.storageRoot 4096 ["-C", binding.source, "status", "--porcelain"]
        source @?= ""
        metadata <- right =<< run env (Execution.inspectExecution snapshot.executionId)
        assertBool "commit message remains outside public metadata" (not ("PRIVATE_COMMIT_MESSAGE" `Text.isInfixOf` Text.pack (show (Aeson.encode metadata)))),
      testCase "lost publication acknowledgement settles its original actual after authority and ownership freeze" $ withGit fixture "commit" \env binding snapshot access reference runtime profile backend -> do
        profileReady env binding profile
        Bytes.writeFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") "new dependency\n"
        reached <- newIORef False
        let interrupted = backend & #afterPublication .~ (writeIORef reached True >> throwIO (userError "fixture lost Git acknowledgement"))
        execute (Fixture.executorForAdapter (workspaceGitAdapterWithBackend interrupted) runtime) snapshot reference
        readIORef reached >>= (@?= True)
        Just before <- right =<< run env (Execution.inspectExecutionAttempt reference.attemptId)
        before.phase @?= Attempt.AttemptUncertain
        run env (runTransaction (Store.freezeWorkspaceTx binding binding.request.owner 0)) >>= (@?= Right ())
        scan <- right =<< scanGitReceipts env Nothing
        scan.inspected @?= 1
        scan.acknowledged @?= 1
        Just original <- right =<< run env (Execution.inspectExecutionAttempt reference.attemptId)
        original.phase @?= Attempt.AttemptCommitted
        assertBool "original independent receipt retained" (original.lateReceipt /= Nothing)
        (_, state) <- right =<< run env (Execution.loadExecution access)
        state.cursor @?= 2
        root <- right =<< run env (Roots.inspectRoot binding.request.rootId)
        root.active @?= 0
        root.unknown @?= 1,
      testCase "replacement observation never republishes and independently closes the superseded original" $ withGit fixture "commit" \env binding snapshot access reference runtime profile backend -> do
        profileReady env binding profile
        Bytes.writeFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") "new dependency\n"
        writes <- newIORef (0 :: Int)
        let interrupted = backend & #afterPublication .~ (modifyIORef' writes (+ 1) >> throwIO (userError "fixture lost Git acknowledgement"))
            executor = Fixture.executorForAdapter (workspaceGitAdapterWithBackend interrupted) runtime
        execute executor snapshot reference
        (_, uncertain) <- right =<< run env (Execution.loadExecution access)
        let replacement = reference & #attemptId .~ AttemptId "git-replacement"
            tool = head snapshot.toolBindings
            submission = Attempt.AttemptSubmission (Execution.toolAttemptRequest replacement.attemptId replacement.operationId tool) Nothing (Attempt.ExecutionWake (AwakeableId UUID.nil) 0)
        _ <- right =<< run env (Execution.recoverExecutionAttemptWith access uncertain.revision reference.attemptId submission (\_ -> pure ()))
        execute executor snapshot replacement
        readIORef writes >>= (@?= 1)
        (_, before) <- right =<< run env (Execution.loadExecution access)
        before.cursor @?= 2
        before.pendingReceipts @?= 1
        publishGitReceipt env reference.operationId >>= (@?= Right GitReceiptAcknowledged)
        (_, after) <- right =<< run env (Execution.loadExecution access)
        after.cursor @?= before.cursor
        after.pendingReceipts @?= 0
        Just retained <- run env (runTransaction (Git.inspectGitTx reference.operationId))
        retained.attemptId @?= reference.attemptId,
      testCase "status and diff are bounded admitted observations with no commit registration" $
        mapM_
          ( \name -> withGit fixture name \env binding snapshot access reference runtime profile backend -> do
              profileReady env binding profile
              Bytes.writeFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") "new dependency\n"
              execute (Fixture.executorForAdapter (workspaceGitAdapterWithBackend backend) runtime) snapshot reference
              Objects.readHead (workspaceMetadata binding.storageRoot binding) >>= (@?= Right binding.base)
              run env (runTransaction (Git.inspectGitTx reference.operationId)) >>= (@?= Nothing)
              Just operation <- right =<< run env (Execution.inspectOperation reference.operationId)
              result <- maybe (fail "missing observation result") pure operation.outcome
              output <- right =<< run env (Execution.readReplayPayload @OperationOutcome access "operation-outcome" result)
              let text = Text.pack (show (Aeson.encode output))
              assertBool "result names the changed path" ("src/dependency.txt" `Text.isInfixOf` text)
              if name == "diff" then assertBool "diff contains the admitted change" ("new dependency" `Text.isInfixOf` text) else pure ()
          )
          ["status", "diff"],
      testCase "fresh denial before publication leaves HEAD unchanged and retains a proven refusal" $ withGit fixture "commit" \env binding snapshot _ reference runtime profile backend -> do
        profileReady env binding profile
        Bytes.writeFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") "new dependency\n"
        let denied = runtime & #authorizer .~ denyAllActionAuthorizer
        execute (Fixture.executorForAdapter (workspaceGitAdapterWithBackend backend) denied) snapshot reference
        Objects.readHead (workspaceMetadata binding.storageRoot binding) >>= (@?= Right binding.base)
        Just record <- run env (runTransaction (Git.inspectGitTx reference.operationId))
        record.phase @?= GitRefused,
      testCase "loss after publication admission cannot authorize a replacement HEAD update" $ withGit fixture "commit" \env binding snapshot access reference runtime profile backend -> do
        profileReady env binding profile
        Bytes.writeFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") "new dependency\n"
        let stopAfterGrant _ = do
              record <- run env (runTransaction (Git.inspectGitTx reference.operationId))
              if maybe False ((== GitPublishRequested) . (.phase)) record then pure (Left "fixture revoked") else pure (Right ())
            interrupted = runtime & #lifecycle .~ stopAfterGrant
        execute (Fixture.executorForAdapter (workspaceGitAdapterWithBackend backend) interrupted) snapshot reference
        Objects.readHead (workspaceMetadata binding.storageRoot binding) >>= (@?= Right binding.base)
        publishGitReceipt env reference.operationId >>= (@?= Right AwaitingGitReceipt)
        Just record <- run env (runTransaction (Git.inspectGitTx reference.operationId))
        record.phase @?= GitUnresolved
        run env (runTransaction (Store.checkWorkspaceOperationTx binding binding.request.owner 0 (OperationId "successor"))) >>= (@?= Left WorkspaceBindingConflict)
        (_, state) <- right =<< run env (Execution.loadExecution access)
        state.phase @?= Unresolved,
      testCase "unsettled processes block Git observations and commits before capture" $
        mapM_
          ( \name -> withGit fixture name \env binding snapshot _ reference runtime profile backend -> do
              profileReady env binding profile
              now <- getCurrentTime
              let operation = OperationId "pending-validation"
                  digest = profile.instructionDigest
                  command = commandFor digest (head profile.policy.rules)
                  record = ProcessRecord operation (AttemptId "pending-attempt") "pending-owner" 1 (workspaceBindingDigest binding) digest digest command (addUTCTime 30 now) (processUnit operation digest) Nothing Nothing ProcessReserved Nothing Nothing
              _ <- right =<< run env (runTransaction (Processes.reserveProcessTx binding record))
              captured <- newIORef (0 :: Int)
              let counting = backend & #capture .~ (\b p target policy -> modifyIORef' captured (+ 1) >> backend.capture b p target policy)
              execute (Fixture.executorForAdapter (workspaceGitAdapterWithBackend counting) runtime) snapshot reference
              readIORef captured >>= (@?= 0)
              run env (runTransaction (Git.inspectGitTx reference.operationId)) >>= (@?= Nothing)
              Objects.readHead (workspaceMetadata binding.storageRoot binding) >>= (@?= Right binding.base)
          )
          ["status", "diff", "commit"],
      testCase "a changed path outside frozen write scope refuses publication" $ withGit fixture "commit" \env binding snapshot _ reference runtime profile backend -> do
        profileReady env binding profile
        Bytes.writeFile (workspaceFiles binding.storageRoot binding </> "AGENTS.md") "changed root instructions\n"
        execute (Fixture.executorForAdapter (workspaceGitAdapterWithBackend backend) runtime) snapshot reference
        Objects.readHead (workspaceMetadata binding.storageRoot binding) >>= (@?= Right binding.base)
        Just record <- run env (runTransaction (Git.inspectGitTx reference.operationId))
        record.phase @?= GitRefused
        record.candidate @?= Nothing,
      testCase "reserved profiles refuse before capture or publication" $ withGit fixture "commit" \env binding snapshot _ reference runtime _ backend -> do
        captured <- newIORef (0 :: Int)
        let counting = backend & #capture .~ (\b p target policy -> modifyIORef' captured (+ 1) >> backend.capture b p target policy)
        execute (Fixture.executorForAdapter (workspaceGitAdapterWithBackend counting) runtime) snapshot reference
        readIORef captured >>= (@?= 0)
        run env (runTransaction (Git.inspectGitTx reference.operationId)) >>= (@?= Nothing)
        Objects.readHead (workspaceMetadata binding.storageRoot binding) >>= (@?= Right binding.base),
      testCase "stale actual generation refuses before capture or publication" $ withGit fixture "commit" \env binding snapshot _ reference runtime profile backend -> do
        profileReady env binding profile
        captured <- newIORef (0 :: Int)
        let counting = backend & #capture .~ (\b p target policy -> modifyIORef' captured (+ 1) >> backend.capture b p target policy)
            broken r = let adapter = workspaceGitAdapterWithBackend counting r in DurableAdapter adapter.descriptor adapter.contracts (\s d name -> adapter.prepare s (d & #generation .~ (d.generation + 1)) name)
        execute (Fixture.executorForAdapter broken runtime) snapshot reference
        readIORef captured >>= (@?= 0)
        run env (runTransaction (Git.inspectGitTx reference.operationId)) >>= (@?= Nothing)
        Objects.readHead (workspaceMetadata binding.storageRoot binding) >>= (@?= Right binding.base)
    ]

withGit :: DatabaseFixture -> Text.Text -> (AppEnv -> WorkspaceBinding -> ExecutionSnapshot -> Execution.ReplayAccess -> Attempt.JobReference -> FileRuntime -> ProcessProfile -> GitBackend -> IO a) -> IO a
withGit fixture name use = do
  properties <- Systemd.systemdPropertiesIdentity
  let digest = "sha256:" <> Text.replicate 64 "a"
      policy = ProcessPolicy 1 (ProcessImage "/qualified/root" digest "/bin/env" "/bin/deadline" "/qualified/collector") properties [CommandRule "validate" "/bin/validate" [] "" Map.empty 30 1024] [""] ["src"]
      backend = GitBackend (pure (Right "11111111-1111-4111-8111-111111111111")) fixtureCapture (pure ())
      input binding = Just (if name == "commit" then Aeson.toJSON (GitCommitRequest binding.base "chore(deps): PRIVATE_COMMIT_MESSAGE") else Aeson.object [])
  Fixture.withEffectAdapterPolicyInput (Just policy) 1 (\admission -> admission & #filePolicy .~ Just supervisedFilePolicy) (workspaceGitAdapterWithBackend backend) ("overlay__workspace-git__" <> name) name input fixture \env binding snapshot access reference runtime _ -> do
    admission <- maybe (fail "missing Git admission") pure snapshot.workspace
    (profile, _) <- right =<< run env (runTransaction (reserveProcessProfileTx binding (bundleDigest admission.instructions) policy (IdentityRange 62000 62001)))
    use env binding snapshot access reference runtime profile backend

fixtureCapture :: WorkspaceBinding -> ProcessProfile -> Text.Text -> (Text.Text -> IO (Either WorkspaceError ())) -> IO (Either WorkspaceError CapturedTree)
fixtureCapture binding _ target admit = do
  let paths = ["AGENTS.md", "src/AGENTS.md", "src/dependency.txt"]
      metadata = workspaceMetadata binding.storageRoot binding
  entries <-
    mapM
      ( \path -> do
          _ <- right =<< admit path
          result <- withContainedFile (workspaceFiles binding.storageRoot binding) path (readContainedFile 262144)
          bytes <- maybe (fail "fixture file missing") pure =<< right result
          blob <- right =<< Objects.storeBlob metadata bytes
          pure (Objects.GitEntry path "100644" blob)
      )
      paths
  tree <- Objects.storeFlatTree metadata entries
  pure ((\object -> CapturedTree target object paths) <$> tree)

profileReady :: AppEnv -> WorkspaceBinding -> ProcessProfile -> IO ()
profileReady env binding profile = run env (runTransaction (readyProcessProfileTx binding profile)) >>= (@?= Right ())

execute :: Executor.ExecutionRuntime -> ExecutionSnapshot -> Attempt.JobReference -> IO ()
execute executor snapshot reference = Executor.executeAcceptedAttempt executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure
