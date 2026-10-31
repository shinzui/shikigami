-- Real accepted-executor/database evidence with an instrumented backend.
-- These cases do not establish Linux service, restart or cgroup qualification.
module Shikigami.WorkspaceSupervisorSpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Exception (throwIO)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (Eff)
import Effectful.Dispatch.Static (unsafeEff_)
import Hasql.Transaction (Transaction)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization
import Shikigami.Agent.Principal (AgentIdentity (CompatibilityIdentity))
import Shikigami.App (AppEffects, runAppIO)
import Shikigami.Capability.Provider (DurableAdapter (..), DurableToolContract (..))
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Resources (Root (..))
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Runner (DispatchContext (..), OperationContext (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude ((&), (.~))
import Shikigami.Workspace.FileProvider (FileRuntime (..))
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessProvider
import Shikigami.Workspace.ProcessStore qualified as Processes
import Shikigami.Workspace.Rpc
import Shikigami.Workspace.Service
import Shikigami.Workspace.Store qualified as Workspaces
import Shikigami.Workspace.Supervisor
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.Types
import Shikigami.WorkspaceFileProviderSpec qualified as Fixture
import Shikigami.WorkspaceRpcSpec (withListener)
import Shikumi.Tool (mkDynTool)
import System.Directory (removeFile)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace accepted process supervisor"
    [ testCase "transfer-aware process revision uses the peer service and independent original-attempt publisher" $ withProcessVersion True 1 fixture id True \file runtime _ calls snapshot reference -> withListener \path listener uid -> do
        let client = ProcessClient path uid 3 3
        withAsync (serveRpc (RpcPolicy [uid] 2 3) listener (dispatchSupervisorRpc runtime)) \_ -> do
          Executor.executeAcceptedAttempt (Fixture.executorForAdapter (const (transferredWorkspaceExecAdapter client)) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          publishProcessReceipt runtime reference.operationId >>= (@?= Right ProcessReceiptAcknowledged)
          readIORef calls >>= (@?= (1, 1)),
      testCase "retained root cancellation requests stop after revocation and never fabricates settlement" $ rootCancellationCase fixture True,
      testCase "a failed cancellation request remains unresolved and never fabricates settlement" $ rootCancellationCase fixture False,
      testCase "independent service recovers facts in the background with no connected worker" $ withProcess fixture id False \file runtime observed calls snapshot reference -> do
        Executor.executeAcceptedAttempt (Fixture.executorForAdapter (adapter runtime observed) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        let revoked = runtime & #replayAuthority .~ const (pure (Left "revoked")) & #lifecycle .~ const (pure (Left "revoked")) & #authorizer .~ denyAllActionAuthorizer & #selectRule .~ (\_ _ _ -> pure (Left "revoked"))
            waitCommitted = do
              actual <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
              case actual of
                Just record | record.phase == Attempt.AttemptCommitted -> pure ()
                _ -> threadDelay 20000 >> waitCommitted
        withListener \_ listener uid ->
          withAsync (serveSupervisor (RpcPolicy [uid] 2 3) listener revoked) \_ ->
            timeout 5000000 waitCommitted >>= (@?= Just ())
        readIORef calls >>= (@?= (1, 1)),
      testCase "independent paged scan acknowledges original facts without a worker request or live read authority" $ withProcess fixture id False \file runtime observed calls snapshot reference -> do
        Executor.executeAcceptedAttempt (Fixture.executorForAdapter (adapter runtime observed) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        let revoked = runtime & #replayAuthority .~ const (pure (Left "revoked")) & #lifecycle .~ const (pure (Left "revoked")) & #authorizer .~ denyAllActionAuthorizer & #selectRule .~ (\_ _ _ -> pure (Left "revoked"))
        page <- right =<< scanProcessReceipts revoked Nothing
        page.inspected @?= 1
        page.acknowledged @?= 1
        page.pending @?= 0
        page.cursor @?= Just reference.operationId
        next <- right =<< scanProcessReceipts revoked page.cursor
        next.inspected @?= 0
        next.cursor @?= Nothing
        repeated <- right =<< scanProcessReceipts revoked Nothing
        repeated.acknowledged @?= 1
        Just completed <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
        completed.phase @?= Attempt.AttemptCommitted
        readIORef calls >>= (@?= (1, 1)),
      testCase "accepted executor uses the peer-checked client and server with one original launch and identical receipt acknowledgement" $ withProcess fixture id True \file runtime _ calls snapshot reference ->
        withListener \path listener uid -> do
          let client = ProcessClient path uid 3 5
          withAsync (serveRpc (RpcPolicy [uid] 2 3) listener (dispatchSupervisorRpc runtime)) \_ -> do
            Executor.executeAcceptedAttempt (Fixture.executorForAdapter (const (workspaceExecAdapter client)) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
            Just actual <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
            actual.phase @?= Attempt.AttemptCommitted
            publishProcessReceipt runtime reference.operationId >>= (@?= Right ProcessReceiptAcknowledged)
            readIORef calls >>= (@?= (1, 1)),
      testCase "a failed peer check retains an uncertain accepted attempt without any supervisor launch" $ withProcess fixture id True \file runtime _ calls snapshot reference ->
        withListener \path listener uid -> do
          let client = ProcessClient path ((uid + 1) `mod` 4294967296) 3 5
          withAsync (serveRpc (RpcPolicy [uid] 2 3) listener (dispatchSupervisorRpc runtime)) \_ -> do
            Executor.executeAcceptedAttempt (Fixture.executorForAdapter (const (workspaceExecAdapter client)) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
            Just actual <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
            actual.phase @?= Attempt.AttemptUncertain
            transaction file (Processes.inspectProcessTx reference.operationId) >>= (@?= Nothing)
            readIORef calls >>= (@?= (0, 0)),
      testCase "restarted Unix service observes original facts and acknowledges after authority revocation" $ withProcess fixture id False \file runtime _ calls snapshot reference ->
        withListener \path listener uid -> do
          let client = ProcessClient path uid 3 5
          withAsync (serveRpc (RpcPolicy [uid] 2 3) listener (dispatchSupervisorRpc runtime)) \_ ->
            Executor.executeAcceptedAttempt (Fixture.executorForAdapter (const (workspaceExecAdapter client)) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          Just actual <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
          actual.phase @?= Attempt.AttemptUncertain
          let revoked = runtime & #replayAuthority .~ const (pure (Left "revoked")) & #lifecycle .~ const (pure (Left "revoked")) & #authorizer .~ denyAllActionAuthorizer & #selectRule .~ (\_ _ _ -> pure (Left "revoked"))
          withAsync (serveRpc (RpcPolicy [uid] 2 3) listener (dispatchSupervisorRpc revoked)) \_ -> do
            result <- right =<< callRpc path uid 3 (RpcObserve reference.operationId)
            case result of
              RpcView value -> do
                value.phase @?= ProcessSettled
                value.attemptId @?= reference.attemptId
              _ -> assertFailure "original facts unavailable after restart"
            publishProcessReceipt revoked reference.operationId >>= (@?= Right ProcessReceiptAcknowledged)
            readIORef calls >>= (@?= (1, 1)),
      testCase "actual executor dispatch registers and settles one original launch despite duplicate observation" $ withProcess fixture id True \file runtime observed calls snapshot reference -> do
        readIORef calls >>= (@?= (0, 0))
        Executor.executeAcceptedAttempt (Fixture.executorForAdapter (adapter runtime observed) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        request <- readIORef observed >>= maybe (fail "missing actual request") pure
        Just retained <- transaction file (Processes.inspectProcessTx reference.operationId)
        retained.attemptId @?= reference.attemptId
        retained.generation @?= request.generation
        retained.phase @?= ProcessSettled
        Just receipt <- pure retained.receipt
        assertBool "only confirmed zero normal exit succeeds" (processSucceeded receipt)
        superviseProcess runtime request >>= (@?= Right retained)
        superviseProcess runtime (request & #generation .~ (request.generation + 1)) >>= (@?= Right retained)
        publishProcessReceipt runtime reference.operationId >>= (@?= Right ProcessReceiptAcknowledged)
        readIORef calls >>= (@?= (1, 1)),
      testCase "lost launch acknowledgement reconciles facts after revocation without dispatching another command" $ withProcess fixture id False \file runtime observed calls snapshot reference -> do
        Executor.executeAcceptedAttempt (Fixture.executorForAdapter (adapter runtime observed) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        request <- readIORef observed >>= maybe (fail "missing actual request") pure
        Just old <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
        old.phase @?= Attempt.AttemptUncertain
        let revoked = runtime & #replayAuthority .~ const (pure (Left "revoked")) & #lifecycle .~ const (pure (Left "revoked")) & #selectRule .~ (\_ _ _ -> pure (Left "revoked"))
        recovered <- right =<< reconcileProcess revoked reference.operationId
        recovered.phase @?= ProcessSettled
        recovered.attemptId @?= reference.attemptId
        superviseProcess runtime request >>= (@?= Right recovered)
        readIORef calls >>= (@?= (1, 1))
        -- Workspace facts and original-attempt accounting are separate owners.
        Just stillUnknown <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
        stillUnknown.phase @?= Attempt.AttemptUncertain
        Just admission <- pure snapshot.workspace
        root <- stored file (Roots.inspectRoot admission.rootId)
        root.unknown @?= 2
        stored file (Roots.setRootControl admission.rootId root.revision True Nothing)
        Just (waiting, _, _) <- stored file (Execution.inspectExecution snapshot.executionId)
        let claim = Attempt.AttemptClaim reference request.owner request.generation
            invalid = Attempt.AttemptResult (OperationDenied "not a retained tool result") NeedModel Nothing
        runAppIO file.appEnv (Execution.recordIndependentToolReceipt (CompatibilityIdentity "other-principal") waiting.revision claim invalid) >>= (\value -> right value >>= (@?= Left ExecutionIdentityConflict))
        runAppIO file.appEnv (Execution.recordIndependentToolReceipt snapshot.identity waiting.revision (claim & #generation .~ (claim.generation + 1)) invalid) >>= (\value -> right value >>= (@?= Left AttemptConflict))
        runAppIO file.appEnv (Execution.recordIndependentToolReceipt snapshot.identity waiting.revision claim invalid) >>= (\value -> right value >>= (@?= Left AttemptConflict))
        publishProcessReceipt revoked reference.operationId >>= (@?= Right ProcessReceiptAcknowledged)
        publishProcessReceipt revoked reference.operationId >>= (@?= Right ProcessReceiptAcknowledged)
        Just acknowledged <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
        acknowledged.phase @?= Attempt.AttemptCommitted
        assertBool "original independent receipt retained" (maybe False (const True) acknowledged.lateReceipt)
        settled <- stored file (Roots.inspectRoot admission.rootId)
        -- The fixture model has separate unreported invoice billing. Factual
        -- tool settlement must preserve that unrelated conservative hold.
        settled.unknown @?= 1
        settled.active @?= 0
        settled.cancelled @?= True
        readIORef calls >>= (@?= (1, 1)),
      testCase "independent receipt recovery preserves the next accepted tool after replay authority is revoked" $ withProcessForTools 2 fixture id False \file runtime observed calls snapshot reference -> do
        Executor.executeAcceptedAttempt (Fixture.executorForAdapter (adapter runtime observed) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        let revoked = runtime & #replayAuthority .~ const (pure (Left "revoked")) & #lifecycle .~ const (pure (Left "revoked")) & #authorizer .~ denyAllActionAuthorizer & #selectRule .~ (\_ _ _ -> pure (Left "revoked"))
        publishProcessReceipt revoked reference.operationId >>= (@?= Right ProcessReceiptAcknowledged)
        Just (state, _, _) <- stored file (Execution.inspectExecution snapshot.executionId)
        state.cursor @?= 2
        case state.next of
          NeedTool _ position -> position @?= 1
          _ -> assertFailure "accepted second tool routing was lost"
        Just actual <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
        actual.phase @?= Attempt.AttemptCommitted
        readIORef calls >>= (@?= (1, 1)),
      testCase "the independent owner waits for actual claim expiry before acknowledging its retained receipt" $ withProcess fixture id True \file runtime _ calls snapshot reference -> do
        access <- stored file (Execution.authorizeReplay snapshot.executionId snapshot.identity (pure (Right ())))
        Just (before, _, _) <- stored file (Execution.inspectExecution snapshot.executionId)
        Attempt.ClaimGranted claim <- stored file (Execution.claimExecutionAttempt access before.revision reference "lost-worker" 3)
        Just (claimed, _, _) <- stored file (Execution.inspectExecution snapshot.executionId)
        _ <- stored file (Execution.startExecutionAttempt access claimed.revision claim)
        let request = SupervisorRequest snapshot.executionId reference.operationId reference.attemptId claim.owner claim.generation
        record <- right =<< superviseProcess runtime request
        record.phase @?= ProcessSettled
        publishProcessReceipt runtime reference.operationId >>= (@?= Right AwaitingExecutionExpiry)
        Just pending <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
        pending.phase @?= Attempt.DispatchStarted
        threadDelay 3200000
        let revoked = runtime & #replayAuthority .~ const (pure (Left "revoked")) & #lifecycle .~ const (pure (Left "revoked"))
        publishProcessReceipt revoked reference.operationId >>= (@?= Right ProcessReceiptAcknowledged)
        Just completed <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
        completed.phase @?= Attempt.AttemptCommitted
        readIORef calls >>= (@?= (1, 1)),
      testCase "denied exact authority proves pre-launch refusal and cannot be retried into a launch" $ withProcess fixture (\runtime -> runtime & #authorizer .~ denyAllActionAuthorizer) True \file runtime observed calls snapshot reference -> do
        Executor.executeAcceptedAttempt (Fixture.executorForAdapter (adapter runtime observed) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        request <- readIORef observed >>= maybe (fail "missing actual request") pure
        Just retained <- transaction file (Processes.inspectProcessTx reference.operationId)
        retained.phase @?= ProcessRefused
        retained.receipt @?= Nothing
        readIORef calls >>= (@?= (0, 0))
        superviseProcess (runtime & #authorizer .~ allowAllActionAuthorizerForTests) request >>= (@?= Right retained)
        publishProcessReceipt runtime reference.operationId >>= (@?= Right ProcessReceiptAcknowledged)
        readIORef calls >>= (@?= (0, 0)),
      testCase "a refusal after the committed launch transition remains uncertain rather than a known no-op" $ do
        checks <- newIORef (0 :: Int)
        let gate _ = atomicModifyIORef' checks (\count -> (count + 1, count)) >>= \count -> pure (if count < 3 then Right () else Left "revoked at launch boundary")
        withProcess fixture (\runtime -> runtime & #lifecycle .~ gate) True \file runtime observed calls snapshot reference -> do
          Executor.executeAcceptedAttempt (Fixture.executorForAdapter (adapter runtime observed) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          Just retained <- transaction file (Processes.inspectProcessTx reference.operationId)
          retained.phase @?= ProcessUnresolved
          retained.receipt @?= Nothing
          Just actual <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
          actual.phase @?= Attempt.AttemptUncertain
          readIORef calls >>= (@?= (1, 0)),
      testCase "a substituted actual claim generation refuses before reserving or preparing capture" $ withProcess fixture id True \file runtime observed calls snapshot reference -> do
        let changed request = request & #generation .~ (request.generation + 1)
        Executor.executeAcceptedAttempt (Fixture.executorForAdapter (adapterWithRequest changed runtime observed) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        transaction file (Processes.inspectProcessTx reference.operationId) >>= (@?= Nothing)
        readIORef calls >>= (@?= (0, 0)),
      testCase "lost or failed capture without completion evidence keeps process and actual attempt unresolved" $ do
        let configure marker runtime =
              runtime
                & #backend
                .~ SupervisorBackend
                  runtime.backend.bootIdentity
                  runtime.backend.capture
                  ( \profile files scratch directory record -> do
                      result <- runtime.backend.launch profile files scratch directory record
                      removeFile (directory </> "complete.json")
                      if marker then Bytes.writeFile (directory </> "unresolved.json") "{\"stage\":7}" else pure ()
                      pure result
                  )
                  (const (pure (Right marker)))
                  runtime.backend.stop
        mapM_
          ( \marker -> withProcess fixture (configure marker) True \file runtime observed calls snapshot reference -> do
              Executor.executeAcceptedAttempt (Fixture.executorForAdapter (adapter runtime observed) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
              Just retained <- transaction file (Processes.inspectProcessTx reference.operationId)
              retained.phase @?= ProcessUnresolved
              retained.receipt @?= Nothing
              reconcileProcess runtime reference.operationId >>= (@?= Right retained)
              Just actual <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
              actual.phase @?= Attempt.AttemptUncertain
              readIORef calls >>= (@?= (1, 1))
          )
          [False, True],
      testCase "ownership freeze refuses actual process dispatch before launch registration" $ withProcess fixture id True \file runtime observed calls snapshot reference -> do
        Just admission <- pure snapshot.workspace
        Just (binding, _) <- transaction file (Workspaces.inspectWorkspaceTx admission.workspace)
        transaction file (Workspaces.freezeWorkspaceTx binding binding.request.owner binding.request.epoch) >>= (@?= Right ())
        Executor.executeAcceptedAttempt (Fixture.executorForAdapter (adapter runtime observed) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        transaction file (Processes.inspectProcessTx reference.operationId) >>= (@?= Nothing)
        readIORef calls >>= (@?= (0, 0))
    ]

withProcess :: DatabaseFixture -> (SupervisorRuntime -> SupervisorRuntime) -> Bool -> (FileRuntime -> SupervisorRuntime -> IORef (Maybe SupervisorRequest) -> IORef (Int, Int) -> ExecutionSnapshot -> Attempt.JobReference -> IO a) -> IO a
withProcess = withProcessForTools 1

withProcessForTools :: Int -> DatabaseFixture -> (SupervisorRuntime -> SupervisorRuntime) -> Bool -> (FileRuntime -> SupervisorRuntime -> IORef (Maybe SupervisorRequest) -> IORef (Int, Int) -> ExecutionSnapshot -> Attempt.JobReference -> IO a) -> IO a
withProcessForTools = withProcessVersion False

withProcessVersion :: Bool -> Int -> DatabaseFixture -> (SupervisorRuntime -> SupervisorRuntime) -> Bool -> (FileRuntime -> SupervisorRuntime -> IORef (Maybe SupervisorRequest) -> IORef (Int, Int) -> ExecutionSnapshot -> Attempt.JobReference -> IO a) -> IO a
withProcessVersion transferred toolCount fixture configure acknowledge use = do
  observed <- newIORef Nothing
  calls <- newIORef (0, 0)
  let backend =
        SupervisorBackend
          (pure (Right boot))
          (\_ directory _ -> modifyIORef' calls (\(captures, starts) -> (captures + 1, starts)) >> Bytes.writeFile (directory </> "ready") "1\n" >> pure (Right ()))
          ( \_ _ _ directory record -> do
              modifyIORef' calls (\(captures, starts) -> (captures, starts + 1))
              Bytes.writeFile (directory </> "stdout") ""
              Bytes.writeFile (directory </> "stderr") ""
              Lazy.writeFile
                (directory </> "complete.json")
                ( Aeson.encode
                    ( Aeson.object
                        [ "version" .= (2 :: Int),
                          "unit" .= record.unit,
                          "fingerprint" .= record.fingerprint,
                          "bootId" .= boot,
                          "invocationId" .= ("22222222222222222222222222222222" :: Text.Text),
                          "exitCode" .= (0 :: Int),
                          "termination" .= ProcessExited,
                          "stdoutBytes" .= (0 :: Int),
                          "stderrBytes" .= (0 :: Int),
                          "stdoutTruncated" .= False,
                          "stderrTruncated" .= False,
                          "descendantsEmpty" .= True,
                          "outputComplete" .= True
                        ]
                    )
                )
              pure (if acknowledge then Right () else Left Systemd.SystemdUncertain)
          )
          (const (pure (Right True)))
          (const (pure (Right ())))
      makeRuntime file = configure (SupervisorRuntime file.appEnv file.authorizer (const (pure (Right ()))) file.lifecycle select backend)
      install file = adapterWithVersion transferred id (makeRuntime file) observed file
      qualify admission = admission & #filePolicy .~ Just (if transferred then transferableFilePolicy else supervisedFilePolicy)
  Fixture.withEffectAdapterForTools toolCount qualify install workspaceExecBinding.name "validate" (Just (Aeson.object ["rule" .= ("validate" :: Text.Text)])) fixture \_ _ snapshot _ reference file _ ->
    use file (makeRuntime file) observed calls snapshot reference
  where
    boot = "11111111-1111-4111-8111-111111111111"
    select _ _ rule = do
      let profile = Systemd.SystemdProfile "/qualified/root" ("sha256:" <> Text.replicate 64 "a") "/bin/env" "/bin/deadline" "/qualified/collector" 62001 62001
      identity <- Systemd.systemdProfileIdentity profile
      pure (if rule == "validate" then Right (ProcessCommand rule identity "/bin/validate" [] "" (Map.singleton "HOME" "/scratch") 30 1024, profile) else Left "unknown fixture rule")

adapter :: SupervisorRuntime -> IORef (Maybe SupervisorRequest) -> FileRuntime -> DurableAdapter
adapter = adapterWithRequest id

adapterWithRequest :: (SupervisorRequest -> SupervisorRequest) -> SupervisorRuntime -> IORef (Maybe SupervisorRequest) -> FileRuntime -> DurableAdapter
adapterWithRequest = adapterWithVersion False

adapterWithVersion :: Bool -> (SupervisorRequest -> SupervisorRequest) -> SupervisorRuntime -> IORef (Maybe SupervisorRequest) -> FileRuntime -> DurableAdapter
adapterWithVersion transferred alter runtime observed file = DurableAdapter (if transferred then transferredWorkspaceExecDescriptor else workspaceExecDescriptor) [DurableToolContract "validate" "Validate one reviewed rule." workspaceExecSchema UncertainEffect NoInvoiceCost] \snapshot dispatch name ->
  pure
    ( Right
        ( mkDynTool name "Validate one reviewed rule." workspaceExecSchema \(_input :: Aeson.Value) -> unsafeEff_ do
            let request = SupervisorRequest snapshot.executionId dispatch.operation.operationId dispatch.attemptId dispatch.owner dispatch.generation
            writeIORef observed (Just request)
            result <- superviseProcess runtime (alter request)
            case result of
              Right record | Just output <- processToolResult record -> pure output
              Left SupervisorRefused -> do
                retained <- transaction file (Processes.inspectProcessTx request.operationId)
                case retained of
                  Just record | Just output <- processToolResult record -> pure output
                  _ -> throwIO (userError "workspace process refusal requires reconciliation")
              _ -> throwIO (userError "workspace process receipt requires reconciliation")
        )
    )

transaction :: FileRuntime -> Transaction a -> IO a
transaction file action = right =<< runAppIO file.appEnv (runTransaction action)

stored :: (Show e) => FileRuntime -> Eff AppEffects (Either e a) -> IO a
stored file action = right =<< (right =<< runAppIO file.appEnv action)

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

rootCancellationCase :: DatabaseFixture -> Bool -> IO ()
rootCancellationCase fixture stopAcknowledged = do
  stops <- newIORef (0 :: Int)
  directory <- newIORef Nothing
  let configure runtime =
        runtime
          & #backend
          .~ ( ( runtime.backend
                   & #launch
                   .~ ( \profile files scratch target record -> do
                          result <- runtime.backend.launch profile files scratch target record
                          writeIORef directory (Just target)
                          removeFile (target </> "complete.json")
                          pure result
                      )
                   & #stop
                   .~ ( \_ -> do
                          target <- readIORef directory >>= maybe (fail "missing fixture capture") pure
                          Bytes.readFile (target </> "cancel") >>= (@?= "1\n")
                          modifyIORef' stops (+ 1)
                          pure (if stopAcknowledged then Right () else Left Systemd.SystemdUncertain)
                      )
               )
             )
  withProcess fixture configure True \file runtime observed calls snapshot reference -> do
    Executor.executeAcceptedAttempt (Fixture.executorForAdapter (adapter runtime observed) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
    readIORef stops >>= (@?= 0)
    Just admission <- pure snapshot.workspace
    root <- stored file (Roots.inspectRoot admission.rootId)
    stored file (Roots.setRootControl admission.rootId root.revision True Nothing)
    let revoked = runtime & #authorizer .~ denyAllActionAuthorizer & #replayAuthority .~ const (pure (Left "revoked")) & #lifecycle .~ const (pure (Left "revoked")) & #selectRule .~ (\_ _ _ -> pure (Left "revoked"))
    page <- right =<< scanProcessReceipts revoked Nothing
    page.acknowledged @?= 0
    page.pending @?= 1
    readIORef stops >>= (@?= 1)
    Just retained <- transaction file (Processes.inspectProcessTx reference.operationId)
    retained.receipt @?= Nothing
    retained.phase @?= (if stopAcknowledged then ProcessLaunchRequested else ProcessUnresolved)
    readIORef calls >>= (@?= (1, 1))
