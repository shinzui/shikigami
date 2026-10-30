module Shikigami.WorkspaceTransferSpec (tests) where

import Control.Concurrent.Async (withAsync)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff)
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.App (AppEffects, AppEnv, runAppIO)
import Kioku.Id (genSessionId)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization
import Shikigami.Agent.Decl (defaultDelegationBudget)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Delegate.Depth (DelegationDepth (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Execution.Identity (AttemptId (..), ExecutionRootId (..), OperationId (..))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Store.ExecutionResources qualified as Roots
import Shikigami.WorkerSession.Checkpoint (ObjectiveVersion (..))
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Transfer
import Shikigami.WorkerSession.Types
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.ContainedFile (ensurePrivateDirectory, withWorkspaceLock)
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessProvider (ProcessClient (..))
import Shikigami.Workspace.ProcessStore qualified as Processes
import Shikigami.Workspace.Rpc
import Shikigami.Workspace.Store qualified as Workspaces
import Shikigami.Workspace.Supervisor
import Shikigami.Workspace.Transfer
import Shikigami.Workspace.TransferClient
import Shikigami.Workspace.Types
import Shikigami.WorkspaceRpcSpec (withListener)
import Shikigami.WorkspaceStoreSpec qualified as Fixture
import System.Directory (createDirectory, doesFileExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace concrete transfer owner"
    [ testCase "private peer client recovers one retained fence across service restart and revocation" $ withTransfer fixture \env binding intent runtime _ -> withListener \path listener uid -> do
        let client = workspaceTransferClient (ProcessClient path uid 3 3)
            serve selected = serveRpc (RpcPolicy [uid] 2 3) listener (dispatchSupervisorRpc selected)
        proof <- withAsync (serve runtime) \_ -> do
          outcome <- client.reconcile intent
          case outcome of
            FencedAndSettled value -> pure value
            _ -> assertFailure (show outcome) >> fail "missing fence"
        assertBool "full retained coordinates match" (matchesFence intent proof)
        withAsync (serve (runtime & #authorizer .~ denyAllActionAuthorizer & #replayAuthority .~ const (pure (Left "revoked")))) \_ -> do
          client.reconcile intent >>= (@?= FencedAndSettled proof)
          client.admitWrite binding.workspace intent.sessionId intent.oldOwner 0 (OperationId "late-old") >>= assertRefused
          client.admitWrite binding.workspace intent.sessionId intent.newOwner 1 (OperationId "premature-successor") >>= assertRefused
        run env (runTransaction (Workspaces.inspectWorkspaceTx binding.workspace)) >>= (@?= Just (binding, Ready)),
      testCase "freeze cancels the retained process but cannot prove descendant settlement from a stop request" $ withTransferProcess fixture \env binding intent runtime record stopped -> do
        provider <- pure (workspaceTransferProvider runtime)
        provider.reconcile intent >>= (@?= FenceUnresolved)
        readIORef stopped >>= (@?= 1)
        doesFileExist (processDirectory binding record </> "cancel") >>= (@?= True)
        readFile (workspaceFiles binding.storageRoot binding </> "dependency.txt") >>= (@?= "old dependency\n")
        provider.admitWrite binding.workspace intent.sessionId intent.newOwner 1 (OperationId "premature") >>= assertRefused
        -- Instrumented factual backend evidence, not a real process qualification.
        let empty = CapturedOutput "stdout" ("sha256:" <> Text.replicate 64 "b") 0 False
            receipt = ProcessReceipt record.operationId record.attemptId record.generation record.fingerprint record.bindingDigest record.unit boot invocation (Just 143) ProcessCancelled empty (empty & #artifact .~ "stderr") True True
        run env (runTransaction (Processes.recordProcessReceiptTx receipt)) >>= (@?= Right ())
        outcome <- (workspaceTransferProvider (runtime & #authorizer .~ denyAllActionAuthorizer)).reconcile intent
        assertBool "only retained full settlement produces a fence" (case outcome of FencedAndSettled proof -> matchesFence intent proof; _ -> False)
        provider.admitWrite binding.workspace intent.sessionId intent.oldOwner 0 (OperationId "late-old") >>= assertRefused,
      testCase "a reserved process is refused without launch while unknown launch evidence remains pending" $ withTransfer fixture \env binding intent runtime _ -> do
        record <- reserveProcess env binding
        (workspaceTransferProvider runtime).reconcile intent >>= \outcome -> assertBool "proven unlaunched reservation permits settlement" (case outcome of FencedAndSettled proof -> matchesFence intent proof; _ -> False)
        Just retained <- run env (runTransaction (Processes.inspectProcessTx record.operationId))
        retained.phase @?= ProcessRefused,
      testCase "denied fresh authority never freezes or stops an unadmitted workspace" $ withTransferProcess fixture \env binding intent runtime _ stopped -> do
        (workspaceTransferProvider (runtime & #authorizer .~ denyAllActionAuthorizer)).reconcile intent >>= (@?= FenceUnavailable)
        readIORef stopped >>= (@?= 0)
        run env (runTransaction (Workspaces.checkWorkspaceOwnerTx binding intent.oldOwner 0)) >>= (@?= Right ()),
      testCase "an independently held writer lock cannot be mistaken for successful write or fence admission" $ withTransfer fixture \_ binding intent runtime _ -> do
        withWorkspaceLock
          (workspaceMetadata binding.storageRoot binding)
          ( do
              (workspaceTransferProvider runtime).reconcile intent >>= (@?= FenceUnresolved)
              (workspaceTransferProvider runtime).admitWrite binding.workspace intent.sessionId intent.oldOwner 0 (OperationId "locked-write") >>= assertRefused
              pure (Right ())
          )
          >>= (@?= Right ())
    ]

boot, invocation :: Text
boot = "11111111-1111-4111-8111-111111111111"
invocation = "22222222-2222-4222-8222-222222222222"

withTransfer :: DatabaseFixture -> (AppEnv -> WorkspaceBinding -> TransferIntent -> SupervisorRuntime -> IORef Int -> IO a) -> IO a
withTransfer fixture callback = Fixture.withFixture fixture \env _ storage repository -> do
  now <- getCurrentTime
  parentSession <- genSessionId
  parent <- right =<< loadAgent "../agents/heartbeat.dhall"
  let root = ExecutionRootId "transfer-root"
      old = compatibilityIdentity "worker"
      successor = compatibilityIdentity "successor"
      actor = compatibilityIdentity "coordinator"
      session = SessionAdmission 1 (SessionScope "fixture-parent" "worker") (ObjectiveRef "fixture-checkpoints" "objective") (parent & #name .~ "coordinator" & #delegates .~ ["worker", "successor"]) (DelegateCtx (DelegationDepth 0) actor (Just parentSession) Nothing (Just (WorkflowId "parent")) [AgentName "coordinator"] Nothing (Just root) Nothing defaultDelegationBudget) (AgentName "worker") old 10 4
  _ <- right =<< run env Catalog.registerProjectionCatalog
  run env (Roots.enrollRoot root (Resources.Envelope (Map.fromList [(dimension, Resources.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now))) >>= (@?= Right Resources.Accepted)
  _ <- right =<< run env (Sessions.openSession session)
  access <- right =<< run env (Sessions.authorizeSession (sessionIdFor session) actor (pure (Right ())))
  (_, message) <- right =<< run env (Sessions.acceptMessage access 0 0 (OperationId "send") (Instruction 1 FollowUp "fixture" 1 1 1 Nothing))
  (_, started) <- right =<< run env (Sessions.startAssignment access 1 0 (OperationId "start") message.assignmentId)
  child <- maybe (fail "missing child") pure started.childWorkflowId
  (binding, _) <- right =<< run env (runTransaction (Workspaces.reserveWorkspaceTx storage (WorkspaceRequest child (Just (sessionIdFor session, message.assignmentId)) root old old 0) repository))
  allocateWorkspace storage binding Reserved >>= (@?= Right ())
  run env (runTransaction (Workspaces.markWorkspaceReadyTx binding)) >>= (@?= Right ())
  let version = ObjectiveVersion 1 1 1 0 old True root (addUTCTime 3600 now)
  (_, intent) <- right =<< run env (Sessions.requestTransfer access 2 0 (OperationId "transfer") version binding.workspace (AgentName "successor") successor)
  stopped <- newIORef 0
  let backend = SupervisorBackend (pure (Right boot)) (\_ _ _ -> fail "transfer cannot capture") (\_ _ _ _ _ -> fail "transfer cannot launch") (const (pure (Right True))) (\_ -> modifyIORef' stopped (+ 1) >> pure (Right ()))
      runtime = SupervisorRuntime env allowAllActionAuthorizerForTests (const (pure (Right ()))) (const (pure (Right ()))) (\_ _ _ -> fail "transfer cannot select new commands") backend
  callback env binding intent runtime stopped

reserveProcess :: AppEnv -> WorkspaceBinding -> IO ProcessRecord
reserveProcess env binding = do
  now <- getCurrentTime
  let digest = "sha256:" <> Text.replicate 64 "a"
      operation = OperationId "retained-process"
      command = ProcessCommand "validate" digest "/bin/validate" [] "" Map.empty 30 1024
      record = ProcessRecord operation (AttemptId "original-process-actual") "actual-owner" 1 (workspaceBindingDigest binding) digest digest command (addUTCTime 30 now) (processUnit operation digest) Nothing Nothing ProcessReserved Nothing Nothing
  right =<< run env (runTransaction (Processes.reserveProcessTx binding record))

withTransferProcess :: DatabaseFixture -> (AppEnv -> WorkspaceBinding -> TransferIntent -> SupervisorRuntime -> ProcessRecord -> IORef Int -> IO a) -> IO a
withTransferProcess fixture callback = withTransfer fixture \env binding intent runtime stopped -> do
  record <- reserveProcess env binding
  run env (runTransaction (Processes.requestProcessLaunchTx binding record boot)) >>= (@?= Right True)
  run env (runTransaction (Processes.observeProcessInvocationTx record boot invocation)) >>= (@?= Right ())
  createDirectory (processDirectory binding record)
  ensurePrivateDirectory (processDirectory binding record) >>= (@?= Right ())
  Just current <- run env (runTransaction (Processes.inspectProcessTx record.operationId))
  callback env binding intent runtime current stopped

assertRefused :: Either Text () -> Assertion
assertRefused = \case Left _ -> pure (); Right () -> assertFailure "unsafe write admission"

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure
