-- Accepted executor and real Git evidence. Only native host/tree enumeration
-- is instrumented; native coupled Git qualification remains a separate gate.
module Shikigami.WorkspaceGitProviderSpec (tests) where

import Control.Exception (throwIO)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as Bytes
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Effectful (Eff)
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Capability.Provider (DurableAdapter (..))
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Identity
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Runner (DispatchContext (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude ((&), (.~))
import Shikigami.StateRevision (StateRevision, parseRevision)
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.ContainedFile
import Shikigami.Workspace.FileProvider
import Shikigami.Workspace.Git (runWorkspaceGit)
import Shikigami.Workspace.GitCapture
import Shikigami.Workspace.GitObjects qualified as Objects
import Shikigami.Workspace.GitProvider
import Shikigami.Workspace.GitStore qualified as Git
import Shikigami.Workspace.GitTypes
import Shikigami.Workspace.InstructionLoader
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Integration qualified as Integration
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
    [ testCase "accepted integration combines two retained worker artifacts in a third clean workspace" $ withIntegration fixture False \env target admission runtime backend artifacts -> do
        let input = Aeson.toJSON (Integration.Request target.base artifacts)
        withIntegrationTool env admission runtime backend input \output -> do
          value <- outputValue output
          field "conflicts" value @?= Just (Aeson.toJSON ([] :: [Text.Text]))
          field "paths" value @?= Just (Aeson.toJSON ["src/AGENTS.md", "src/dependency.txt" :: Text.Text])
          assertBool "combined tree retained" (isJustValue (field "tree" value))
          replacements <- case field "replacements" value of Just body -> right (Aeson.fromJSON body `asEither` ()); _ -> fail "missing replacements"
          map (\(replacement :: Replacement) -> replacement.path) replacements @?= ["src/AGENTS.md", "src/dependency.txt"]
          readFile (workspaceFiles target.storageRoot target </> "src/dependency.txt") >>= (@?= "old dependency\n")
          Objects.readHead (workspaceMetadata target.storageRoot target) >>= (@?= Right target.base),
      testCase "unequal overlapping worker changes return conflicts without changing files or HEAD" $ withIntegration fixture True \env target admission runtime backend artifacts ->
        withIntegrationTool env admission runtime backend (Aeson.toJSON (Integration.Request target.base artifacts)) \output -> do
          value <- outputValue output
          field "conflicts" value @?= Just (Aeson.toJSON ["src/dependency.txt" :: Text.Text])
          field "replacements" value @?= Just (Aeson.toJSON ([] :: [Replacement]))
          Objects.readHead (workspaceMetadata target.storageRoot target) >>= (@?= Right target.base),
      testCase "forged artifact coordinates refuse before capture" $ withIntegration fixture False \env target admission runtime backend artifacts -> do
        let forged = head artifacts & #revision .~ Text.replicate 40 "0"
        withIntegrationTool env admission runtime backend (Aeson.toJSON (Integration.Request target.base (forged : tail artifacts))) assertRefused,
      testCase "denied integration authority refuses without changing HEAD" $ withIntegration fixture False \env target admission runtime backend artifacts -> do
        withIntegrationTool env admission (runtime & #authorizer .~ denyAllActionAuthorizer) backend (Aeson.toJSON (Integration.Request target.base artifacts)) assertRefused
        Objects.readHead (workspaceMetadata target.storageRoot target) >>= (@?= Right target.base),
      testCase "dirty integration target refuses rather than overwriting prior work" $ withIntegration fixture False \env target admission runtime backend artifacts -> do
        writeFile (workspaceFiles target.storageRoot target </> "src/dependency.txt") "uncommitted integrator change\n"
        withIntegrationTool env admission runtime backend (Aeson.toJSON (Integration.Request target.base artifacts)) assertRefused
        readFile (workspaceFiles target.storageRoot target </> "src/dependency.txt") >>= (@?= "uncommitted integrator change\n"),
      testCase "transfer-aware Git revision recovers its original exact commit after freeze" $ withGitVersion True fixture "commit" \env binding snapshot _ reference runtime profile backend -> do
        profileReady env binding profile
        publications <- newIORef (0 :: Int)
        Bytes.writeFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") "new dependency\n"
        let interrupted = backend & #afterPublication .~ (modifyIORef' publications (+ 1) >> throwIO (userError "lost transferred Git acknowledgement"))
        execute (Fixture.executorForAdapter (transferredWorkspaceGitAdapterWithBackend interrupted) runtime) snapshot reference
        readIORef publications >>= (@?= 1)
        Just before <- run env (runTransaction (Git.inspectGitTx reference.operationId))
        run env (runTransaction (Store.freezeWorkspaceTx binding binding.request.owner (fixtureRevision 0))) >>= (@?= Right ())
        publishGitReceipt env reference.operationId >>= (@?= Right GitReceiptAcknowledged)
        publishGitReceipt env reference.operationId >>= (@?= Right GitReceiptAcknowledged)
        Just after <- run env (runTransaction (Git.inspectGitTx reference.operationId))
        after.phase @?= GitApplied
        after.candidate @?= before.candidate
        readIORef publications >>= (@?= 1),
      testCase "declared exact commit uses the accepted claim and duplicate delivery creates one commit" $ withGit fixture "commit" \env binding snapshot access reference runtime profile backend -> do
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
        run env (runTransaction (Store.freezeWorkspaceTx binding binding.request.owner (fixtureRevision 0))) >>= (@?= Right ())
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
        run env (runTransaction (Store.checkWorkspaceOperationTx binding binding.request.owner (fixtureRevision 0) (OperationId "successor"))) >>= (@?= Left WorkspaceBindingConflict)
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
withGit = withGitVersion False

withGitVersion :: Bool -> DatabaseFixture -> Text.Text -> (AppEnv -> WorkspaceBinding -> ExecutionSnapshot -> Execution.ReplayAccess -> Attempt.JobReference -> FileRuntime -> ProcessProfile -> GitBackend -> IO a) -> IO a
withGitVersion transferred fixture name use = do
  properties <- Systemd.systemdPropertiesIdentity
  let digest = "sha256:" <> Text.replicate 64 "a"
      policy = ProcessPolicy 1 (ProcessImage "/qualified/root" digest "/bin/env" "/bin/deadline" "/qualified/collector") properties [CommandRule "validate" "/bin/validate" [] "" Map.empty 30 1024] [""] ["src"]
      backend = GitBackend (pure (Right "11111111-1111-4111-8111-111111111111")) fixtureCapture (pure ())
      input binding = Just (if name == "commit" then Aeson.toJSON (GitCommitRequest binding.base "chore(deps): PRIVATE_COMMIT_MESSAGE") else Aeson.object [])
  Fixture.withEffectAdapterPolicyInput (Just policy) 1 (\admission -> admission & #filePolicy .~ Just (if transferred then transferableFilePolicy else supervisedFilePolicy)) ((if transferred then transferredWorkspaceGitAdapterWithBackend else workspaceGitAdapterWithBackend) backend) ("overlay__workspace-git__" <> name) name input fixture \env binding snapshot access reference runtime _ -> do
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

-- All three allocations share one actual execution root and approved base.
-- Source commits use the real accepted Git adapter; only native enumeration is
-- instrumented on Darwin. Applying recipes/validation belongs to Linux gates.
withIntegration :: DatabaseFixture -> Bool -> (AppEnv -> WorkspaceBinding -> WorkspaceAdmission -> FileRuntime -> GitBackend -> [Integration.Artifact] -> IO a) -> IO a
withIntegration fixture conflicting use = withGitVersion True fixture "commit" \env first snapshot _ reference runtime profile backend -> do
  profileReady env first profile
  Bytes.writeFile (workspaceFiles first.storageRoot first </> "src/dependency.txt") "worker one\n"
  execute (Fixture.executorForAdapter (transferredWorkspaceGitAdapterWithBackend backend) runtime) snapshot reference
  firstArtifact <- artifact env reference
  (second, secondAdmission) <- sibling env first profile "worker-two"
  let secondPath = if conflicting then "src/dependency.txt" else "src/AGENTS.md"
  Bytes.writeFile (workspaceFiles second.storageRoot second </> Text.unpack secondPath) "worker two\n"
  token <- UUID.nextRandom
  Fixture.withAcceptedWorkspaceTool 1 (transferredWorkspaceGitAdapterWithBackend backend) (AgentName "worker") "overlay__workspace-git__commit" token env secondAdmission runtime (Aeson.toJSON (GitCommitRequest second.base "Worker two")) \secondSnapshot _ secondReference -> do
    execute (Fixture.executorForAdapter (transferredWorkspaceGitAdapterWithBackend backend) runtime) secondSnapshot secondReference
    secondArtifact <- artifact env secondReference
    (target, admission) <- sibling env first profile "integrator"
    use env target admission runtime backend [firstArtifact, secondArtifact]
  where
    artifact env reference = do
      Just (binding, record) <- run env (runTransaction (Git.inspectRegisteredGitTx reference.operationId))
      record.phase @?= GitApplied
      candidate <- maybe (fail "missing applied artifact") pure record.candidate
      pure (Integration.Artifact reference.operationId (workspaceBindingDigest binding) binding.base candidate.result)

sibling :: AppEnv -> WorkspaceBinding -> ProcessProfile -> Text.Text -> IO (WorkspaceBinding, WorkspaceAdmission)
sibling env original profile runId = do
  catalog <- right (mkWorkspaceCatalog [RepositoryPolicy original.repository original.source [original.base] original.base original.policyRevision])
  repository <- right (resolveRepository catalog original.repository Nothing)
  let request = original.request & #runId .~ runId
  (binding, state) <- right =<< run env (runTransaction (Store.reserveWorkspaceTx original.storageRoot request repository))
  allocateWorkspace original.storageRoot binding state >>= (@?= Right ())
  run env (runTransaction (Store.markWorkspaceReadyTx binding)) >>= (@?= Right ())
  admission <- right =<< loadWorkspaceAdmission binding (runId <> "-assignment") 65536
  (retained, _) <- right =<< run env (runTransaction (reserveProcessProfileTx binding (bundleDigest admission.instructions) profile.policy (IdentityRange 62002 62020)))
  profileReady env binding retained
  pure (binding, admission & #filePolicy .~ Just transferableFilePolicy)

withIntegrationTool :: AppEnv -> WorkspaceAdmission -> FileRuntime -> GitBackend -> Aeson.Value -> (OperationOutcome -> IO a) -> IO a
withIntegrationTool env admission runtime backend input use = do
  token <- UUID.nextRandom
  let adapter = workspaceIntegrationAdapterWithBackend backend
  Fixture.withAcceptedWorkspaceTool 1 adapter (AgentName "worker") integrationBinding.name token env admission runtime input \snapshot access reference -> do
    execute (Fixture.executorForAdapter adapter runtime) snapshot reference
    Just operation <- right =<< run env (Execution.inspectOperation reference.operationId)
    result <- maybe (fail "missing integration result") pure operation.outcome
    output <- right =<< run env (Execution.readReplayPayload @OperationOutcome access "operation-outcome" result)
    use output

outputValue :: OperationOutcome -> IO Aeson.Value
outputValue (RichToolReturned result) | not result.failed = case result.blocks of
  [TextBlock value] -> right (Aeson.eitherDecodeStrict (Encoding.encodeUtf8 value))
  _ -> fail "expected exact integration JSON"
outputValue _ = fail "expected successful integration"

field :: Aeson.Key -> Aeson.Value -> Maybe Aeson.Value
field name (Aeson.Object fields) = KeyMap.lookup name fields
field _ _ = Nothing

isJustValue :: Maybe a -> Bool
isJustValue = maybe False (const True)

asEither :: Aeson.Result a -> () -> Either String a
asEither (Aeson.Success value) _ = Right value
asEither (Aeson.Error err) _ = Left err

assertRefused :: OperationOutcome -> Assertion
assertRefused (ToolReturned _ True) = pure ()
assertRefused (RichToolReturned result) | result.failed = pure ()
assertRefused _ = assertFailure "expected bounded refusal"

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)
