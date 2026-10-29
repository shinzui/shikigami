-- Real accepted-executor/database evidence with an instrumented backend.
-- These cases do not establish Linux service, restart or cgroup qualification.
module Shikigami.WorkspaceSupervisorSpec (tests) where

import Control.Exception (throwIO)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Effectful (Eff)
import Effectful.Dispatch.Static (unsafeEff_)
import Hasql.Transaction (Transaction)
import Kioku.App (AppEffects, runAppIO)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization
import Shikigami.Capability.Provider (DurableAdapter (..), DurableToolContract (..))
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Runner (DispatchContext (..), OperationContext (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude ((&), (.~))
import Shikigami.Workspace.FileProvider (FileRuntime (..))
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessStore qualified as Processes
import Shikigami.Workspace.Store qualified as Workspaces
import Shikigami.Workspace.Supervisor
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.Types
import Shikigami.WorkspaceFileProviderSpec qualified as Fixture
import Shikumi.Tool (ToolError (..), mkDynTool)
import Shikumi.Tool.Output (textToolOutput)
import System.Directory (removeFile)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace accepted process supervisor"
    [ testCase "actual executor dispatch registers and settles one original launch despite duplicate observation" $ withProcess fixture id True \file runtime observed calls snapshot reference -> do
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
        -- Workspace factual settlement alone cannot fabricate execution-accounting
        -- acknowledgement; the independent late-receipt integration is separate.
        Just stillUnknown <- stored file (Execution.inspectExecutionAttempt reference.attemptId)
        stillUnknown.phase @?= Attempt.AttemptUncertain,
      testCase "denied exact authority proves pre-launch refusal and cannot be retried into a launch" $ withProcess fixture (\runtime -> runtime & #authorizer .~ denyAllActionAuthorizer) True \file runtime observed calls snapshot reference -> do
        Executor.executeAcceptedAttempt (Fixture.executorForAdapter (adapter runtime observed) file) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        request <- readIORef observed >>= maybe (fail "missing actual request") pure
        Just retained <- transaction file (Processes.inspectProcessTx reference.operationId)
        retained.phase @?= ProcessRefused
        retained.receipt @?= Nothing
        readIORef calls >>= (@?= (0, 0))
        superviseProcess (runtime & #authorizer .~ allowAllActionAuthorizerForTests) request >>= (@?= Right retained)
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
withProcess fixture configure acknowledge use = do
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
                        [ "version" Aeson..= (2 :: Int),
                          "unit" Aeson..= record.unit,
                          "fingerprint" Aeson..= record.fingerprint,
                          "bootId" Aeson..= boot,
                          "invocationId" Aeson..= ("22222222222222222222222222222222" :: Text.Text),
                          "exitCode" Aeson..= (0 :: Int),
                          "termination" Aeson..= ProcessExited,
                          "stdoutBytes" Aeson..= (0 :: Int),
                          "stderrBytes" Aeson..= (0 :: Int),
                          "stdoutTruncated" Aeson..= False,
                          "stderrTruncated" Aeson..= False,
                          "descendantsEmpty" Aeson..= True,
                          "outputComplete" Aeson..= True
                        ]
                    )
                )
              pure (if acknowledge then Right () else Left Systemd.SystemdUncertain)
          )
          (const (pure (Right True)))
      makeRuntime file = configure (SupervisorRuntime file.appEnv file.authorizer (const (pure (Right ()))) file.lifecycle select backend)
      install file = adapter (makeRuntime file) observed file
      qualify admission = admission & #filePolicy .~ Just supervisedFilePolicy
  Fixture.withEffectAdapter qualify install workspaceExecBinding.name "validate" (Just (Aeson.object ["rule" Aeson..= ("validate" :: Text.Text)])) fixture \_ _ snapshot _ reference file _ ->
    use file (makeRuntime file) observed calls snapshot reference
  where
    boot = "11111111-1111-4111-8111-111111111111"
    select _ _ rule = do
      let profile = Systemd.SystemdProfile "/qualified/root" ("sha256:" <> Text.replicate 64 "a") "/bin/env" "/qualified/collector" 62001 62001
      identity <- Systemd.systemdProfileIdentity profile
      pure (if rule == "validate" then Right (ProcessCommand rule identity "/bin/validate" [] "" (Map.singleton "HOME" "/scratch") 30 1024, profile) else Left "unknown fixture rule")

adapter :: SupervisorRuntime -> IORef (Maybe SupervisorRequest) -> FileRuntime -> DurableAdapter
adapter = adapterWithRequest id

adapterWithRequest :: (SupervisorRequest -> SupervisorRequest) -> SupervisorRuntime -> IORef (Maybe SupervisorRequest) -> FileRuntime -> DurableAdapter
adapterWithRequest alter runtime observed file = DurableAdapter workspaceExecDescriptor [DurableToolContract "validate" "Validate one reviewed rule." workspaceExecSchema UncertainEffect NoInvoiceCost] \snapshot dispatch name ->
  pure
    ( Right
        ( mkDynTool name "Validate one reviewed rule." workspaceExecSchema \(_input :: Aeson.Value) -> unsafeEff_ do
            let request = SupervisorRequest snapshot.executionId dispatch.operation.operationId dispatch.attemptId dispatch.owner dispatch.generation
            writeIORef observed (Just request)
            result <- superviseProcess runtime (alter request)
            case result of
              Right record | record.phase == ProcessSettled -> pure (Right (textToolOutput (Encoding.decodeUtf8 (Lazy.toStrict (Aeson.encode record.receipt)))))
              Left SupervisorRefused -> do
                retained <- transaction file (Processes.inspectProcessTx request.operationId)
                case retained of
                  Just record | record.phase == ProcessRefused -> pure (Left (ToolRunFailed name "workspace validation refused"))
                  _ -> throwIO (userError "workspace process refusal requires reconciliation")
              _ -> throwIO (userError "workspace process receipt requires reconciliation")
        )
    )

transaction :: FileRuntime -> Transaction a -> IO a
transaction file action = right =<< runAppIO file.appEnv (runTransaction action)

stored :: FileRuntime -> Eff AppEffects (Either ExecutionError a) -> IO a
stored file action = right =<< (right =<< runAppIO file.appEnv action)

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure
