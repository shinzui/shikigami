-- Database registration evidence only: these fixtures do not claim a real
-- systemd invocation or establish a process fence.
module Shikigami.WorkspaceProcessStoreSpec (tests) where

import Control.Concurrent.Async (concurrently)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Hasql.Transaction (Transaction)
import Kioku.App (AppEnv, runAppIO)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Principal (AgentIdentity (..))
import Shikigami.Execution.Identity
import Shikigami.Execution.Runner (OperationContext (..))
import Shikigami.Execution.Transcript (ExecutionId (..))
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude ((&), (.~))
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessStore
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Types
import Shikigami.WorkspaceStoreSpec qualified as Fixture
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace process registrations"
    [ testCase "racing reservations and lost launch acknowledgement converge without a second launch grant" $ withProcess fixture \env binding proposed -> do
        (one, two) <- concurrently (run env (reserveProcessTx binding proposed)) (run env (reserveProcessTx binding proposed))
        one @?= Right proposed
        two @?= Right proposed
        let changed = proposed & #command . #arguments .~ ["different"]
        run env (reserveProcessTx binding changed) >>= (@?= Left WorkspaceBindingConflict)
        let otherId = OperationId "other-operation"
            other = proposed & #operationId .~ otherId & #unit .~ processUnit otherId proposed.fingerprint
        run env (reserveProcessTx binding other) >>= (@?= Left WorkspaceBindingConflict)
        run env (Store.checkWorkspaceOperationTx binding binding.request.owner 0 (OperationId "read")) >>= (@?= Left WorkspaceBindingConflict)
        (a, b) <- concurrently (run env (requestProcessLaunchTx binding proposed boot)) (run env (requestProcessLaunchTx binding proposed boot))
        granted <- traverse right [a, b]
        sort granted @?= [False, True]
        let replacement = proposed & #attemptId .~ AttemptId "replacement" & #generation .~ 2 & #deadline .~ addUTCTime 3600 proposed.deadline
        retained <- right =<< run env (reserveProcessTx binding replacement)
        retained.attemptId @?= proposed.attemptId
        retained.deadline @?= proposed.deadline
        run env (requestProcessLaunchTx binding replacement boot) >>= (@?= Right False),
      testCase "a proven pre-launch refusal races the launch grant without inventing a process receipt" $ withProcess fixture \env binding proposed -> do
        _ <- right =<< run env (reserveProcessTx binding proposed)
        (launch, refused) <- concurrently (run env (requestProcessLaunchTx binding proposed boot)) (run env (refuseReservedProcessTx proposed))
        Just actual <- run env (inspectProcessTx proposed.operationId)
        actual.receipt @?= Nothing
        case actual.phase of
          ProcessRefused -> do
            launch @?= Left WorkspaceBindingConflict
            refused @?= Right ()
            run env (Store.checkWorkspaceOperationTx binding binding.request.owner 0 (OperationId "later")) >>= (@?= Right ())
          ProcessLaunchRequested -> do
            launch @?= Right True
            refused @?= Left WorkspaceBindingConflict
            run env (Store.checkWorkspaceOperationTx binding binding.request.owner 0 (OperationId "later")) >>= (@?= Left WorkspaceBindingConflict)
          other -> assertFailure ("unexpected launch/refusal race: " <> show other),
      testCase "missing launch evidence stays unresolved and blocks file reuse until a matching receipt" $ withProcess fixture \env binding proposed -> do
        _ <- right =<< run env (reserveProcessTx binding proposed)
        run env (requestProcessLaunchTx binding proposed boot) >>= (@?= Right True)
        run env (markProcessUnresolvedTx proposed) >>= (@?= Right ())
        run env (requestProcessLaunchTx binding proposed boot) >>= (@?= Right False)
        run env (observeProcessInvocationTx proposed otherBoot invocation) >>= (@?= Left WorkspaceBindingConflict)
        run env (Store.checkWorkspaceOperationTx binding binding.request.owner 0 (OperationId "later")) >>= (@?= Left WorkspaceBindingConflict)
        run env (observeProcessInvocationTx proposed boot invocation) >>= (@?= Right ())
        run env (observeProcessInvocationTx proposed boot otherBoot) >>= (@?= Left WorkspaceBindingConflict)
        run env (recordProcessReceiptTx (receiptFor proposed)) >>= (@?= Right ())
        run env (Store.checkWorkspaceOperationTx binding binding.request.owner 0 (OperationId "later")) >>= (@?= Right ()),
      testCase "factual receipts settle after freeze but cannot replace invocation, output or descendant evidence" $ withProcess fixture \env binding proposed -> do
        _ <- right =<< run env (reserveProcessTx binding proposed)
        run env (requestProcessLaunchTx binding proposed boot) >>= (@?= Right True)
        run env (observeProcessInvocationTx proposed boot invocation) >>= (@?= Right ())
        run env (Store.freezeWorkspaceTx binding binding.request.owner 0) >>= (@?= Right ())
        let receipt = receiptFor proposed
        mapM_
          (\invalid -> run env (recordProcessReceiptTx invalid) >>= (@?= Left WorkspaceBindingConflict))
          [ receipt & #bootId .~ otherBoot,
            receipt & #invocationId .~ otherBoot,
            receipt & #generation .~ 2,
            receipt & #descendantsEmpty .~ False,
            receipt & #outputComplete .~ False,
            receipt & #stdout . #bytes .~ 100000
          ]
        run env (recordProcessReceiptTx receipt) >>= (@?= Right ())
        run env (recordProcessReceiptTx receipt) >>= (@?= Right ())
        run env (recordProcessReceiptTx (receipt & #exitCode .~ 1)) >>= (@?= Left WorkspaceBindingConflict)
        run env (Store.checkWorkspaceOwnerTx binding binding.request.owner 0) >>= (@?= Left WorkspaceBindingConflict)
        Just retained <- run env (inspectProcessTx proposed.operationId)
        retained.phase @?= ProcessSettled
    ]

withProcess :: DatabaseFixture -> (AppEnv -> WorkspaceBinding -> ProcessRecord -> IO a) -> IO a
withProcess fixture use = Fixture.withFixture fixture \env _ root repository -> do
  let owner = CompatibilityIdentity "process-worker"
      request = WorkspaceRequest "process-run" Nothing (ExecutionRootId "process-root") owner owner 0
  (binding, _) <- right =<< run env (Store.reserveWorkspaceTx root request repository)
  allocateWorkspace root binding Reserved >>= (@?= Right ())
  run env (Store.markWorkspaceReadyTx binding) >>= (@?= Right ())
  now <- getCurrentTime
  let command = ProcessCommand "validate" digest "/bin/validate" [] "" (Map.fromList [("HOME", "/scratch"), ("TMPDIR", "/scratch")]) 30 1024
      operation = OperationId "process-operation"
      logical = OperationContext (ExecutionId "process-execution") operation "process-operation" "input-fingerprint" "scope"
      fingerprint = processFingerprint binding digest logical command
      record = ProcessRecord operation (AttemptId "original-attempt") "original-claim" 1 (workspaceBindingDigest binding) digest fingerprint command (addUTCTime 30 now) (processUnit operation fingerprint) Nothing Nothing ProcessReserved Nothing
  use env binding record

receiptFor :: ProcessRecord -> ProcessReceipt
receiptFor record = ProcessReceipt record.operationId record.attemptId record.generation record.fingerprint record.bindingDigest record.unit boot invocation 0 ProcessExited (CapturedOutput "stdout" digest 0 False) (CapturedOutput "stderr" digest 0 False) True True

digest :: Text.Text
digest = "sha256:" <> Text.replicate 64 "a"

boot, otherBoot, invocation :: Text.Text
boot = "11111111-1111-4111-8111-111111111111"
otherBoot = "22222222-2222-4222-8222-222222222222"
invocation = "33333333-3333-4333-8333-333333333333"

run :: AppEnv -> Transaction a -> IO a
run env action = runAppIO env (runTransaction action) >>= right

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure
