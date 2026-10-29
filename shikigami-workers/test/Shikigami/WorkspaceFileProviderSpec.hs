module Shikigami.WorkspaceFileProviderSpec (tests, withEffectAdapter, executorForAdapter) where

import Baikai.Options (emptyOptions)
import Baikai.StopReason (StopReason (ToolUse))
import Control.Exception (throwIO)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.Vector qualified as DataVector
import Effectful (Eff)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Keiro.Workflow.Awakeable.Schema (registerAwakeableTx)
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.App (AppEffects, AppEnv, runAppIO)
import Kioku.Id (genSessionId)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization
import Shikigami.Action.Authorization qualified as Action
import Shikigami.Agent.Decl (Behavior (Skill))
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (AgentIdentity (..))
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Capability.Catalog
import Shikigami.Capability.Overlay
import Shikigami.Capability.Provider
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Decision.ModelCatalog (modelCatalog)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Identity
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.Runner (DispatchContext (..))
import Shikigami.Execution.Selection
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Tools qualified as Tools
import Shikigami.Execution.Transcript
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude ((&), (.~))
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Store.ExecutionResources qualified as Roots
import Shikigami.Store.ExecutionSelection qualified as Calls
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.ContainedFile (withWorkspaceLock)
import Shikigami.Workspace.FileProvider
import Shikigami.Workspace.InstructionLoader
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Provider
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Types
import Shikigami.WorkspaceStoreSpec qualified as Fixture
import System.Directory
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace real file provider"
    [ testCase "accepted durable edit uses both gates and duplicate delivery preserves one result" $ withEffect fixture \env binding snapshot access reference runtime input -> do
        authorizations <- newIORef (0 :: Int)
        let checking = (runtime.authorizer) {Action.authorize = \principal action -> modifyIORef' authorizations (+ 1) >> allowAllActionAuthorizerForTests.authorize principal action}
            executor = executorFor (runtime & #authorizer .~ checking) (pure ())
        Executor.executeAcceptedAttempt executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") >>= (@?= "PRIVATE_REPLACEMENT\n")
        before <- getModificationTime (workspaceFiles binding.storageRoot binding </> "src/dependency.txt")
        count <- readIORef authorizations
        assertBool "fresh authorization before read and write" (count >= 2)
        Executor.executeAcceptedAttempt executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readIORef authorizations >>= (@?= count)
        getModificationTime (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") >>= (@?= before)
        (_, state) <- right =<< run env (Execution.loadExecution access)
        state.cursor @?= 2
        Just operation <- right =<< run env (Execution.inspectOperation reference.operationId)
        assertBool "one chosen result" (maybe False (const True) operation.outcome)
        -- Accepted arguments are protected; replacing content in a callback must
        -- fail before any target IO, even if the actual claim remains live.
        Aeson.toJSON (Replacement "src/dependency.txt" (Just (contentDigest "old dependency\n")) "PRIVATE_REPLACEMENT\n") @?= input
        metadata <- right =<< run env (Execution.inspectExecution snapshot.executionId)
        assertBool "public metadata excludes source and replacement text" (not ("PRIVATE_REPLACEMENT" `Text.isInfixOf` Text.pack (show (Aeson.encode metadata))))
        pure (),
      testCase "lost receipt acknowledgement recovers the same edit and settles the original actual attempt" $ withEffect fixture \env binding snapshot access reference runtime _ -> do
        lost <- newIORef False
        let checkpoint = do
              previous <- atomicModifyIORef' lost (\value -> (True, value))
              if previous then pure () else throwIO (userError "fixture lost acknowledgement")
            executor = executorFor runtime checkpoint
        Executor.executeAcceptedAttempt executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        (_, uncertain) <- right =<< run env (Execution.loadExecution access)
        uncertain.phase @?= Unresolved
        uncertain.cursor @?= 1
        path <- pure (workspaceFiles binding.storageRoot binding </> "src/dependency.txt")
        readFile path >>= (@?= "PRIVATE_REPLACEMENT\n")
        published <- getModificationTime path
        Just old <- right =<< run env (Execution.inspectExecutionAttempt reference.attemptId)
        old.phase @?= Attempt.AttemptUncertain
        let next = reference & #attemptId .~ AttemptId "file-attempt-recovery"
            tool = head snapshot.toolBindings
            replacementRequest = Execution.toolAttemptRequest next.attemptId next.operationId tool
            submission = Attempt.AttemptSubmission replacementRequest Nothing (Attempt.ExecutionWake (AwakeableId UUID.nil) 0)
        _ <- right =<< run env (Execution.recoverExecutionAttemptWith access uncertain.revision reference.attemptId submission (\_ -> pure ()))
        Executor.executeAcceptedAttempt executor snapshot.identity next >>= (@?= Right Executor.ExecutorDone)
        getModificationTime path >>= (@?= published)
        (_, resumed) <- right =<< run env (Execution.loadExecution access)
        resumed.cursor @?= 2
        resumed.pendingReceipts @?= 0
        Just original <- right =<< run env (Execution.inspectExecutionAttempt reference.attemptId)
        assertBool "independent receipt settles original claim" (maybe False (const True) original.lateReceipt)
        root <- right =<< run env (Roots.inspectRoot binding.request.rootId)
        -- The fixture model reply has unreported invoice cost. The recovered
        -- file attempt adds no remaining uncertainty or active reservation.
        root.unknown @?= 1
        root.active @?= 0,
      testCase "a crash after prepared intent never attributes a replacement write to the old actual attempt" $ withEffect fixture \env binding snapshot access reference runtime _ -> do
        calls <- newIORef (0 :: Int)
        let interrupted =
              (runtime.authorizer)
                { Action.authorize = \principal action -> do
                    ordinal <- atomicModifyIORef' calls (\n -> (n + 1, n))
                    if ordinal == 1 then throwIO (userError "fixture interrupted before publication") else allowAllActionAuthorizerForTests.authorize principal action
                }
            executor = executorFor (runtime & #authorizer .~ interrupted) (pure ())
        Executor.executeAcceptedAttempt executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        (_, uncertain) <- right =<< run env (Execution.loadExecution access)
        uncertain.phase @?= Unresolved
        readFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") >>= (@?= "old dependency\n")
        let next = reference & #attemptId .~ AttemptId "prepared-recovery"
            tool = head snapshot.toolBindings
            submission = Attempt.AttemptSubmission (Execution.toolAttemptRequest next.attemptId next.operationId tool) Nothing (Attempt.ExecutionWake (AwakeableId UUID.nil) 0)
        _ <- right =<< run env (Execution.recoverExecutionAttemptWith access uncertain.revision reference.attemptId submission (\_ -> pure ()))
        Executor.executeAcceptedAttempt executor snapshot.identity next >>= (@?= Right Executor.ExecutorDone)
        (_, retained) <- right =<< run env (Execution.loadExecution access)
        retained.phase @?= Unresolved
        retained.cursor @?= 1
        retained.pendingReceipts @?= 1
        readFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") >>= (@?= "old dependency\n")
        Just original <- right =<< run env (Execution.inspectExecutionAttempt reference.attemptId)
        original.lateReceipt @?= Nothing,
      testCase "freeze at the write boundary prevents publication and retains a settled refusal" $ withEffect fixture \env binding snapshot _ reference runtime _ -> do
        calls <- newIORef (0 :: Int)
        let revoke =
              (runtime.authorizer)
                { Action.authorize = \principal action -> do
                    ordinal <- atomicModifyIORef' calls (\n -> (n + 1, n))
                    if ordinal == 1
                      then do
                        run env (runTransaction (Store.freezeWorkspaceTx binding snapshot.identity 0)) >>= (@?= Right ())
                        allowAllActionAuthorizerForTests.authorize principal action
                      else allowAllActionAuthorizerForTests.authorize principal action
                }
        Executor.executeAcceptedAttempt (executorFor (runtime & #authorizer .~ revoke) (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") >>= (@?= "old dependency\n")
        -- A proven pre-publication refusal is settled metadata, not an invented
        -- applied edit; the frozen owner still cannot admit another operation.
        run env (runTransaction (Store.checkWorkspaceOwnerTx binding snapshot.identity 0)) >>= (@?= Left WorkspaceBindingConflict),
      testCase "frozen scoped instructions reach operator policy and explicit conflicts refuse before IO" $ withEffect fixture \_ binding snapshot _ reference runtime _ -> do
        checked <- newIORef ([] :: [Text.Text])
        authorizations <- newIORef (0 :: Int)
        writeFile (workspaceFiles binding.storageRoot binding </> "AGENTS.md") "changed worktree policy"
        let targetPolicy _ _ entries kind path = do
              kind @?= "replace"
              path @?= "src/dependency.txt"
              writeIORef checked (map (.text) entries)
              pure (Left "explicit operator policy conflict")
            authority = (runtime.authorizer) {Action.authorize = \principal action -> modifyIORef' authorizations (+ 1) >> allowAllActionAuthorizerForTests.authorize principal action}
            restricted = runtime & #admitTarget .~ targetPolicy & #authorizer .~ authority
        Executor.executeAcceptedAttempt (executorFor restricted (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readIORef checked >>= (@?= ["PRIVATE_ROOT_POLICY: validate before commit", "PRIVATE_NESTED_POLICY: scope source changes"])
        readIORef authorizations >>= (@?= 0)
        readFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") >>= (@?= "old dependency\n"),
      testCase "contained reads return protected content hashes without changing the workspace" $ withEffectFor "read" Nothing fixture \env binding snapshot access reference runtime _ -> do
        let path = workspaceFiles binding.storageRoot binding </> "src/dependency.txt"
        before <- getModificationTime path
        Executor.executeAcceptedAttempt (executorFor runtime (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        getModificationTime path >>= (@?= before)
        Just operation <- right =<< run env (Execution.inspectOperation reference.operationId)
        result <- maybe (fail "missing read outcome") pure operation.outcome
        output <- right =<< run env (Execution.readReplayPayload @OperationOutcome access "operation-outcome" result)
        assertBool "protected read outcome carries content and exact hash" (all (`Text.isInfixOf` Text.pack (show (Aeson.encode output))) ["old dependency", contentDigest "old dependency\n"])
        run env (runTransaction (Store.checkWorkspaceOperationTx binding snapshot.identity 0 (OperationId "later"))) >>= (@?= Right ()),
      testCase "denied exact authority refuses before reserving or changing files" $ withEffect fixture \env binding snapshot _ reference runtime _ -> do
        Executor.executeAcceptedAttempt (executorFor (runtime & #authorizer .~ denyAllActionAuthorizer) (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") >>= (@?= "old dependency\n")
        run env (runTransaction (Store.checkWorkspaceOperationTx binding snapshot.identity 0 (OperationId "later"))) >>= (@?= Right ()),
      testCase "an independently held workspace lock retains uncertainty without publishing" $ withEffect fixture \env binding snapshot access reference runtime _ -> do
        withWorkspaceLock
          (workspaceMetadata binding.storageRoot binding)
          ( do
              Executor.executeAcceptedAttempt (executorFor runtime (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
              pure (Right ())
          )
          >>= (@?= Right ())
        (_, state) <- right =<< run env (Execution.loadExecution access)
        state.phase @?= Unresolved
        state.cursor @?= 1
        readFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") >>= (@?= "old dependency\n"),
      testCase "historical workspace admission without file qualification refuses before IO" $ withEffectQualified (#filePolicy .~ Nothing) "replace" Nothing fixture \env binding snapshot _ reference runtime _ -> do
        Executor.executeAcceptedAttempt (executorFor runtime (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") >>= (@?= "old dependency\n")
        run env (runTransaction (Store.checkWorkspaceOperationTx binding snapshot.identity 0 (OperationId "later"))) >>= (@?= Right ()),
      testCase "content conflicts and hostile accepted paths refuse without effects" $ do
        withEffect fixture \env binding snapshot _ reference runtime _ -> do
          let path = workspaceFiles binding.storageRoot binding </> "src/dependency.txt"
          writeFile path "operator update\n"
          Executor.executeAcceptedAttempt (executorFor runtime (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          readFile path >>= (@?= "operator update\n")
          run env (runTransaction (Store.checkWorkspaceOperationTx binding snapshot.identity 0 (OperationId "later"))) >>= (@?= Right ())
        withEffectFor "replace" (Just (Aeson.toJSON (Replacement "../escape" Nothing "FORGED"))) fixture \_ binding snapshot _ reference runtime _ -> do
          Executor.executeAcceptedAttempt (executorFor runtime (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          readFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") >>= (@?= "old dependency\n"),
      testCase "substituted inputs and stale claim generations refuse before file IO" $ withEffect fixture \_ binding snapshot _ reference runtime input -> do
        let normal = executorFor runtime (pure ())
            protected =
              normal
                { Executor.withTools = \accepted context requested use -> do
                    replaceWorkspaceFile runtime accepted (context & #generation .~ (context.generation + 1)) input >>= (@?= Left FileEffectRefused)
                    replaceWorkspaceFile runtime accepted context (Aeson.toJSON (Replacement "src/dependency.txt" Nothing "FORGED")) >>= (@?= Left FileEffectRefused)
                    case normal of Executor.ExecutionRuntime {Executor.withTools = actual} -> actual accepted context requested use
                }
        Executor.executeAcceptedAttempt protected snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readFile (workspaceFiles binding.storageRoot binding </> "src/dependency.txt") >>= (@?= "PRIVATE_REPLACEMENT\n")
    ]

-- Real migrated execution/resource stores supply all operation and attempt
-- coordinates. Only the fixture model response is supplied deterministically.
withEffect :: DatabaseFixture -> (AppEnv -> WorkspaceBinding -> ExecutionSnapshot -> Execution.ReplayAccess -> Attempt.JobReference -> FileRuntime -> Aeson.Value -> IO a) -> IO a
withEffect = withEffectFor "replace" Nothing

withEffectFor :: Text.Text -> Maybe Aeson.Value -> DatabaseFixture -> (AppEnv -> WorkspaceBinding -> ExecutionSnapshot -> Execution.ReplayAccess -> Attempt.JobReference -> FileRuntime -> Aeson.Value -> IO a) -> IO a
withEffectFor = withEffectQualified id

withEffectQualified :: (WorkspaceAdmission -> WorkspaceAdmission) -> Text.Text -> Maybe Aeson.Value -> DatabaseFixture -> (AppEnv -> WorkspaceBinding -> ExecutionSnapshot -> Execution.ReplayAccess -> Attempt.JobReference -> FileRuntime -> Aeson.Value -> IO a) -> IO a
withEffectQualified qualify logical = withEffectAdapter qualify workspaceEditAdapter ("overlay__workspace-edit__" <> logical) logical

-- Shared accepted-executor fixture for native workspace adapters. This supplies
-- real protected input and actual claims, never synthesized dispatch authority.
withEffectAdapter :: (WorkspaceAdmission -> WorkspaceAdmission) -> (FileRuntime -> DurableAdapter) -> Text.Text -> Text.Text -> Maybe Aeson.Value -> DatabaseFixture -> (AppEnv -> WorkspaceBinding -> ExecutionSnapshot -> Execution.ReplayAccess -> Attempt.JobReference -> FileRuntime -> Aeson.Value -> IO a) -> IO a
withEffectAdapter qualify install wire logical supplied fixture use = Fixture.withFixture fixture \env source root _ -> do
  createDirectory (source </> "src")
  renameFile (source </> "dependency.txt") (source </> "src/dependency.txt")
  writeFile (source </> "AGENTS.md") "PRIVATE_ROOT_POLICY: validate before commit"
  writeFile (source </> "src/AGENTS.md") "PRIVATE_NESTED_POLICY: scope source changes"
  repository <- Fixture.commitRepository source
  let identity = CompatibilityIdentity "worker"
      rootId = ExecutionRootId "file-root"
      request = WorkspaceRequest "file-run" Nothing rootId identity identity 0
      runtime = FileRuntime env allowAllActionAuthorizerForTests (const (pure (Right ()))) (const (pure (Right ()))) (\_ _ _ _ _ -> pure (Right ()))
      input = maybe (if logical == "read" then Aeson.object ["path" Aeson..= ("src/dependency.txt" :: Text.Text)] else Aeson.toJSON (Replacement "src/dependency.txt" (Just (contentDigest "old dependency\n")) "PRIVATE_REPLACEMENT\n")) id supplied
      assignment = "file-execution"
  (binding, _) <- right =<< run env (runTransaction (Store.reserveWorkspaceTx root request repository))
  allocateWorkspace root binding Reserved >>= (@?= Right ())
  run env (runTransaction (Store.markWorkspaceReadyTx binding)) >>= (@?= Right ())
  admission <- qualify <$> (right =<< loadWorkspaceAdmission binding assignment 65536)
  now <- getCurrentTime
  session <- genSessionId
  selection <- right (resolveExecutionSelection assignment (must (modelCatalog [])) (defaultBinding stubModel emptyOptions) Nothing Nothing Nothing Nothing (Just rootId) now)
  let adapter = install runtime
  registry <- right (installDurableAdapters [adapter] emptyCapabilityProviderRegistry)
  catalog <- right (mkCapabilityCatalog [adapter.descriptor])
  capabilities <- right (resolveGovernedCapabilityOverlays (durableAdapterInstalled registry) catalog (\_ _ -> Right ()) (ResolutionSubject (Just "worker") Durable (Skill "fixture") Nothing) [adapter.descriptor.capability])
  let initial = ExecutionSnapshot 1 (executionIdFor assignment) "file-run" (AgentName "worker") identity session selection Nothing (SkillInstructions "fixture" "system" "body") (ReplayContext 2 (Just (instructionPrompt admission.instructions)) [RequestTurn [TextBlock "edit fixture"] Nothing]) capabilities (Aeson.toJSON ([] :: [Aeson.Value])) defaultHarnessPolicy [] (Just admission)
      native = Tools.NativeToolFactory (\_ -> pure (Right [])) (\_ _ _ -> pure (Right []))
  menu <- right =<< Tools.describeExecutionTools Log.silentLogger allowAllActionAuthorizerForTests registry native initial
  let chosen = filter (\tool -> tool.name == wire) menu.toolBindings
      tool = case chosen of [value] -> value; _ -> error "missing fixture file binding"
      snapshot = initial & #offeredTools .~ Aeson.toJSON (filterTools menu.offeredTools) & #toolBindings .~ [tool]
      model = OperationSpec (operationIdFor snapshot.executionId 0) ModelTurn RepeatableObservation "model" (versionedDigest "shikigami.harness-policy/1" (Aeson.toJSON snapshot.policy)) "scope" Nothing
  _ <- right =<< run env Catalog.registerProjectionCatalog
  run env (Roots.enrollRoot rootId (Resources.Envelope (Map.fromList [(dimension, Resources.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now))) >>= (@?= Right Resources.Accepted)
  run env (Execution.admitExecution snapshot) >>= (@?= Right Resources.Accepted)
  access <- right =<< run env (Execution.authorizeReplay snapshot.executionId identity (pure (Right ())))
  (_, operation) <- right =<< run env (Execution.acceptOperation access 0 model (Aeson.object []))
  let OperationId operationKey = operation.specification.operationId
      modelRequest = Resources.AttemptRequest (AttemptId ("model:" <> operationKey)) operation.specification.operationId (Map.fromList [(Resources.ActiveWork, 1), (Resources.ModelAttempts, 1), (Resources.Tokens, 10), (Resources.CostMicroUsd, 0)]) Resources.EnforcedCeiling
  reservation <- right =<< run env (Calls.reserveSelectionCall selection (Calls.CallLimits Nothing Nothing Nothing Nothing Nothing) modelRequest "fixture-model" now)
  call <- case reservation of Calls.NewCall value -> pure value; _ -> fail "new fixture call required"
  let assistant = ReplayAssistant 1 [ToolBlock (ToolInvocation "replace-call" tool.name input)] ToolUse Nothing Nothing (Aeson.object []) Nothing
      outcome = ModelReturned assistant Nothing
  response <- right (Execution.outcomeReference outcome)
  run env (Execution.recordOutcomeAndAdvance access 1 operation.specification.operationId outcome (NeedTool response 0) (Just (call, Calls.CallOutcome Calls.CallTerminal (Map.singleton Resources.Tokens 1) [Resources.CostMicroUsd] Nothing Nothing Nothing))) >>= (@?= Right Resources.Accepted)
  let toolInput = ToolOperationInput response 0 (ToolInvocation "replace-call" tool.name input) tool
      specification = OperationSpec (operationIdFor snapshot.executionId 1) ToolOperation tool.recovery tool.name (versionedDigest "shikigami.harness-policy/1" (Aeson.toJSON snapshot.policy)) (toolScopeDigest tool) (Just 0)
      reference = Attempt.JobReference 1 snapshot.executionId specification.operationId (AttemptId "file-attempt")
      submission = Attempt.AttemptSubmission (Execution.toolAttemptRequest reference.attemptId reference.operationId tool) Nothing (Attempt.ExecutionWake (AwakeableId UUID.nil) 0)
  _ <- right =<< run env (Execution.acceptOperation access 2 specification (Aeson.toJSON toolInput))
  run env (runTransaction (registerAwakeableTx UUID.nil "shikigami.execution" (executionWorkflowId snapshot.executionId).unWorkflowId))
  _ <- right =<< run env (Execution.submitExecutionAttemptWith access 3 submission (\_ -> pure ()))
  use env binding snapshot access reference runtime input
  where
    filterTools (Aeson.Array values) = Aeson.Array (filterVector values)
    filterTools value = value
    filterVector = DataVector.filter (\value -> case value of Aeson.Object fields -> AesonKeyMap.lookup "name" fields == Just (Aeson.String wire); _ -> False)

executorFor :: FileRuntime -> IO () -> Executor.ExecutionRuntime
executorFor runtime checkpoint = executorForAdapter (workspaceEditAdapterWithCheckpoint checkpoint) runtime

executorForAdapter :: (FileRuntime -> DurableAdapter) -> FileRuntime -> Executor.ExecutionRuntime
executorForAdapter install runtime = Executor.ExecutionRuntime runtime.appEnv (const (pure (Right ()))) runtime.lifecycle (\_ -> error "fixture never dispatches a model") (Tools.withExecutionTools Log.silentLogger runtime.authorizer registry native) 5
  where
    registry = must (installDurableAdapters [install runtime] emptyCapabilityProviderRegistry)
    native = Tools.NativeToolFactory (\_ -> pure (Right [])) (\_ _ _ -> pure (Right []))

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

must :: (Show e) => Either e a -> a
must = either (error . show) id
