{-# LANGUAGE DataKinds #-}

module Shikigami.WorkspaceFileProviderSpec (tests, withEffectAdapter, withEffectAdapterForTools, withEffectAdapterPolicyInput, withAcceptedWorkspaceTool, executorForAdapter) where

import Baikai.Options (emptyOptions)
import Baikai.StopReason (StopReason (ToolUse))
import Control.Exception (throwIO)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as AssignmentText
import Data.Text qualified as ClaimText
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.Vector qualified as DataVector
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Keiro.Workflow.Awakeable.Schema (registerAwakeableTx)
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.Id (genSessionId)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization
import Shikigami.Action.Authorization qualified as Action
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl (Behavior (Skill))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, agentNameText, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (..))
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Behavior.Provider.Coordinate qualified as ProviderValue
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Capability.Catalog
import Shikigami.Capability.Overlay
import Shikigami.Capability.Provider
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Decision.ModelCatalog (modelCatalog)
import Shikigami.Duration
import Shikigami.Execution.AssignmentKey (AssignmentKey, parseAssignmentKey)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Claim qualified as Claim
import Shikigami.Execution.Coordinate qualified as ExecutionValue
import Shikigami.Execution.Counter (AttemptCount, parseAttemptCount)
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Identity
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Progress (ProgressNumber (..))
import Shikigami.Execution.Quantity (ResourceAmount, parseResourceAmount)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Runner (DispatchContext (..))
import Shikigami.Execution.Selection
import Shikigami.Execution.SelectionStore qualified as Calls
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.ToolPosition (ToolPosition, parseToolPosition)
import Shikigami.Execution.Tools qualified as Tools
import Shikigami.Execution.Transcript
import Shikigami.Fixture.ExecutionIdentity (fixtureAttemptId, fixtureOperationId, fixtureRootId)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude ((&), (.~))
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.StateRevision (StateRevision, parseRevision)
import Shikigami.StateRevision qualified as Generation
import Shikigami.Trigger.Schedule (parseCron)
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.ContainedFile (withWorkspaceLock)
import Shikigami.Workspace.FileProvider
import Shikigami.Workspace.InstructionLoader
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.ProcessProfileStore
import Shikigami.Workspace.ProcessStore qualified as Processes
import Shikigami.Workspace.Provider
import Shikigami.Workspace.Service (FileScan (..), scanFileReceipts)
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value
import Shikigami.WorkspaceStoreSpec qualified as Fixture
import System.Directory
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace real file provider"
    [ testCase "corrupt file registration preserves the original unresolved edit" (corruptRegisteredFile fixture),
      testCase "independent file recovery settles the original edit after freeze and revoked replay authority" $ withEffect fixture \env binding snapshot access reference runtime _ -> do
        let checkpoint = throwIO (userError "fixture interrupted after publication")
        Executor.executeAcceptedAttempt (executorFor runtime checkpoint) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        (_, uncertain) <- right =<< run env (Execution.loadExecution access)
        uncertain.phase @?= Unresolved
        run env (runTransaction (Store.freezeWorkspaceTx binding snapshot.identity (fixtureRevision 0))) >>= (@?= Right ())
        let path = workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt"
        published <- getModificationTime path
        -- The factual API accepts only an operation id, never current authority,
        -- protected tool arguments or a proposed successor's claimed result.
        publishFileReceipt env reference.operationId >>= (@?= Right FileReceiptAcknowledged)
        publishFileReceipt env reference.operationId >>= (@?= Right FileReceiptAcknowledged)
        getModificationTime path >>= (@?= published)
        readFile path >>= (@?= "PRIVATE_REPLACEMENT\n")
        Just original <- right =<< run env (Execution.inspectExecutionAttempt reference.attemptId)
        original.phase @?= Attempt.AttemptCommitted
        Just (state, _, _) <- right =<< run env (Execution.inspectExecution snapshot.executionId)
        state.cursor @?= (fixtureRevision 2)
        state.pendingReceipts @?= (fixtureProgress 0)
        scan <- right =<< scanFileReceipts env Nothing
        scan.inspected @?= 1
        scan.acknowledged @?= 1
        scan.pending @?= 0
        empty <- right =<< scanFileReceipts env scan.cursor
        empty.inspected @?= 0
        empty.cursor @?= Nothing
        root <- right =<< run env (Roots.inspectRoot binding.request.rootId)
        root.unknown @?= (fixtureCount 1)
        root.active @?= (fixtureCount 0),
      testCase "independent file recovery settles a superseded actual without replacement IO" $ withEffect fixture \env binding snapshot access reference runtime _ -> do
        Executor.executeAcceptedAttempt (executorFor runtime (throwIO (userError "lost publication acknowledgement"))) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        (_, uncertain) <- right =<< run env (Execution.loadExecution access)
        let next = reference & #attemptId .~ fixtureAttemptId "independent-replacement"
            tool = head snapshot.toolBindings
            submission = Attempt.AttemptSubmission (Execution.toolAttemptRequest next.attemptId next.operationId tool) Nothing (Attempt.ExecutionWake (AwakeableId UUID.nil) ExecutionValue.initialExecutionGeneration)
        _ <- right =<< run env (Execution.recoverExecutionAttemptWith access uncertain.revision reference.attemptId submission (\_ -> pure ()))
        run env (runTransaction (Store.freezeWorkspaceTx binding snapshot.identity (fixtureRevision 0))) >>= (@?= Right ())
        publishFileReceipt env reference.operationId >>= (@?= Right FileReceiptAcknowledged)
        Just original <- right =<< run env (Execution.inspectExecutionAttempt reference.attemptId)
        original.phase @?= Attempt.AttemptSuperseded
        assertBool "original late receipt retained" (maybe False (const True) original.lateReceipt)
        Just (state, _, _) <- right =<< run env (Execution.inspectExecution snapshot.executionId)
        state.pendingReceipts @?= (fixtureProgress 0)
        state.cursor @?= (fixtureRevision 1),
      testCase "independent recovery preserves uncertainty when prepared bytes were never published" $ withEffect fixture \env binding snapshot _ reference runtime _ -> do
        calls <- newIORef (0 :: Int)
        let interrupted =
              (runtime.authorizer)
                { Action.authorize = \principal action -> do
                    ordinal <- atomicModifyIORef' calls (\n -> (n + 1, n))
                    if ordinal == 1 then throwIO (userError "interrupted before publication") else allowAllActionAuthorizerForTests.authorize principal action
                }
        Executor.executeAcceptedAttempt (executorFor (runtime & #authorizer .~ interrupted) (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        run env (runTransaction (Store.freezeWorkspaceTx binding snapshot.identity (fixtureRevision 0))) >>= (@?= Right ())
        publishFileReceipt env reference.operationId >>= (@?= Right AwaitingFileReceipt)
        readFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt") >>= (@?= "old dependency\n")
        Just original <- right =<< run env (Execution.inspectExecutionAttempt reference.attemptId)
        original.lateReceipt @?= Nothing
        Just (_, registration, _) <- right =<< run env (runTransaction (Store.inspectRegisteredFileTx reference.operationId))
        run env (runTransaction (Store.registerFileTx binding (registration & #claimOwner .~ (fixtureOwner "forged")))) >>= (@?= Left WorkspaceBindingConflict),
      testCase "independent recovery refuses a substituted target and never searches unregistered operations" $ withEffect fixture \env binding snapshot _ reference runtime _ -> do
        Executor.executeAcceptedAttempt (executorFor runtime (throwIO (userError "lost publication acknowledgement"))) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        let files = workspaceFiles (workspaceLocatorPath binding.storageRoot) binding
        renameDirectory (files </> "src") (files </> "retained-src")
        createDirectory (files </> "src")
        writeFile (files </> "src/dependency.txt") "PRIVATE_REPLACEMENT\n"
        publishFileReceipt env reference.operationId >>= (@?= Right AwaitingFileReceipt)
        publishFileReceipt env (fixtureOperationId "unknown-operation") >>= (@?= Left FileEffectUnresolved),
      testCase "revision 2 reads only with a ready retained profile and exact authority" $ withSupervisedEffect fixture id "read" \env binding snapshot reference runtime profile -> do
        run env (runTransaction (readyProcessProfileTx binding profile)) >>= (@?= Right ())
        calls <- newIORef (0 :: Int)
        let checking = runtime & #authorizer .~ (runtime.authorizer) {Action.authorize = \principal action -> modifyIORef' calls (+ 1) >> allowAllActionAuthorizerForTests.authorize principal action}
        Executor.executeAcceptedAttempt (executorForAdapter supervisedWorkspaceEditAdapter checking) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readIORef calls >>= (@?= 1)
        Just operation <- right =<< run env (Execution.inspectOperation reference.operationId)
        output <- retainedOutput env snapshot operation
        assertBool "retained read contains protected contents" ("old dependency" `Text.isInfixOf` Text.pack (show (Aeson.encode output))),
      testCase "revision 2 refuses reserved profiles before authority or file effects" $ withSupervisedEffect fixture id "read" \env _ snapshot reference runtime _ -> do
        calls <- newIORef (0 :: Int)
        let checking = runtime & #authorizer .~ (runtime.authorizer) {Action.authorize = \principal action -> modifyIORef' calls (+ 1) >> allowAllActionAuthorizerForTests.authorize principal action}
        Executor.executeAcceptedAttempt (executorForAdapter supervisedWorkspaceEditAdapter checking) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readIORef calls >>= (@?= 0)
        Just operation <- right =<< run env (Execution.inspectOperation reference.operationId)
        output <- retainedOutput env snapshot operation
        assertBool "refusal excludes protected contents" (case output of ToolReturned _ ToolFailed -> True; _ -> False),
      testCase "revision 2 enforces retained path restrictions before requesting authority" $ withSupervisedEffect fixture (\policy -> policy & #readPaths .~ [(workspaceCoordinate "lib")]) "read" \env binding snapshot reference runtime profile -> do
        run env (runTransaction (readyProcessProfileTx binding profile)) >>= (@?= Right ())
        calls <- newIORef (0 :: Int)
        let checking = runtime & #authorizer .~ (runtime.authorizer) {Action.authorize = \principal action -> modifyIORef' calls (+ 1) >> allowAllActionAuthorizerForTests.authorize principal action}
        Executor.executeAcceptedAttempt (executorForAdapter supervisedWorkspaceEditAdapter checking) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readIORef calls >>= (@?= 0),
      testCase "revision 2 refuses reads while a retained process is unresolved" $ withSupervisedEffect fixture id "read" \env binding snapshot reference runtime profile -> do
        run env (runTransaction (readyProcessProfileTx binding profile)) >>= (@?= Right ())
        now <- getCurrentTime
        let operation = fixtureOperationId "pending-validation"
            digest :: WorkspaceCoordinate scope
            digest = workspaceCoordinate (workspaceCoordinateText profile.instructionDigest)
            command = commandFor digest (head profile.policy.rules)
            record = ProcessRecord operation (fixtureAttemptId "pending-attempt") (fixtureOwner "pending-owner") (fixtureGeneration 1) (workspaceBindingDigest binding) digest digest command (addUTCTime 30 now) (processUnit operation digest) Nothing Nothing ProcessReserved Nothing Nothing
        _ <- right =<< run env (runTransaction (Processes.reserveProcessTx binding record))
        Executor.executeAcceptedAttempt (executorForAdapter supervisedWorkspaceEditAdapter runtime) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        Just observed <- right =<< run env (Execution.inspectOperation reference.operationId)
        output <- retainedOutput env snapshot observed
        assertBool "pending process blocks protected reads" (case output of ToolReturned _ ToolFailed -> True; _ -> False),
      testCase "accepted durable edit uses both gates and duplicate delivery preserves one result" $ withEffect fixture \env binding snapshot access reference runtime input -> do
        authorizations <- newIORef (0 :: Int)
        let checking = (runtime.authorizer) {Action.authorize = \principal action -> modifyIORef' authorizations (+ 1) >> allowAllActionAuthorizerForTests.authorize principal action}
            executor = executorFor (runtime & #authorizer .~ checking) (pure ())
        Executor.executeAcceptedAttempt executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt") >>= (@?= "PRIVATE_REPLACEMENT\n")
        before <- getModificationTime (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt")
        count <- readIORef authorizations
        assertBool "fresh authorization before read and write" (count >= 2)
        Executor.executeAcceptedAttempt executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readIORef authorizations >>= (@?= count)
        getModificationTime (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt") >>= (@?= before)
        (_, state) <- right =<< run env (Execution.loadExecution access)
        state.cursor @?= (fixtureRevision 2)
        Just operation <- right =<< run env (Execution.inspectOperation reference.operationId)
        assertBool "one chosen result" (maybe False (const True) operation.outcome)
        -- Accepted arguments are protected; replacing content in a callback must
        -- fail before any target IO, even if the actual claim remains live.
        Aeson.toJSON (Replacement (workspaceCoordinate ("src/dependency.txt")) (Just (contentDigest "old dependency\n")) "PRIVATE_REPLACEMENT\n") @?= input
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
        uncertain.cursor @?= (fixtureRevision 1)
        path <- pure (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt")
        readFile path >>= (@?= "PRIVATE_REPLACEMENT\n")
        published <- getModificationTime path
        Just old <- right =<< run env (Execution.inspectExecutionAttempt reference.attemptId)
        old.phase @?= Attempt.AttemptUncertain
        let next = reference & #attemptId .~ fixtureAttemptId "file-attempt-recovery"
            tool = head snapshot.toolBindings
            replacementRequest = Execution.toolAttemptRequest next.attemptId next.operationId tool
            submission = Attempt.AttemptSubmission replacementRequest Nothing (Attempt.ExecutionWake (AwakeableId UUID.nil) ExecutionValue.initialExecutionGeneration)
        _ <- right =<< run env (Execution.recoverExecutionAttemptWith access uncertain.revision reference.attemptId submission (\_ -> pure ()))
        Executor.executeAcceptedAttempt executor snapshot.identity next >>= (@?= Right Executor.ExecutorDone)
        getModificationTime path >>= (@?= published)
        (_, resumed) <- right =<< run env (Execution.loadExecution access)
        resumed.cursor @?= (fixtureRevision 2)
        resumed.pendingReceipts @?= (fixtureProgress 0)
        Just original <- right =<< run env (Execution.inspectExecutionAttempt reference.attemptId)
        assertBool "independent receipt settles original claim" (maybe False (const True) original.lateReceipt)
        root <- right =<< run env (Roots.inspectRoot binding.request.rootId)
        -- The fixture model reply has unreported invoice cost. The recovered
        -- file attempt adds no remaining uncertainty or active reservation.
        root.unknown @?= (fixtureCount 1)
        root.active @?= (fixtureCount 0),
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
        readFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt") >>= (@?= "old dependency\n")
        let next = reference & #attemptId .~ fixtureAttemptId "prepared-recovery"
            tool = head snapshot.toolBindings
            submission = Attempt.AttemptSubmission (Execution.toolAttemptRequest next.attemptId next.operationId tool) Nothing (Attempt.ExecutionWake (AwakeableId UUID.nil) ExecutionValue.initialExecutionGeneration)
        _ <- right =<< run env (Execution.recoverExecutionAttemptWith access uncertain.revision reference.attemptId submission (\_ -> pure ()))
        Executor.executeAcceptedAttempt executor snapshot.identity next >>= (@?= Right Executor.ExecutorDone)
        (_, retained) <- right =<< run env (Execution.loadExecution access)
        retained.phase @?= Unresolved
        retained.cursor @?= (fixtureRevision 1)
        retained.pendingReceipts @?= (fixtureProgress 1)
        readFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt") >>= (@?= "old dependency\n")
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
                        run env (runTransaction (Store.freezeWorkspaceTx binding snapshot.identity (fixtureRevision 0))) >>= (@?= Right ())
                        allowAllActionAuthorizerForTests.authorize principal action
                      else allowAllActionAuthorizerForTests.authorize principal action
                }
        Executor.executeAcceptedAttempt (executorFor (runtime & #authorizer .~ revoke) (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt") >>= (@?= "old dependency\n")
        -- A proven pre-publication refusal is settled metadata, not an invented
        -- applied edit; the frozen owner still cannot admit another operation.
        run env (runTransaction (Store.checkWorkspaceOwnerTx binding snapshot.identity (fixtureRevision 0))) >>= (@?= Left WorkspaceBindingConflict),
      testCase "frozen scoped instructions reach operator policy and explicit conflicts refuse before IO" $ withEffect fixture \_ binding snapshot _ reference runtime _ -> do
        checked <- newIORef ([] :: [Text.Text])
        authorizations <- newIORef (0 :: Int)
        writeFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "AGENTS.md") "changed worktree policy"
        let targetPolicy _ _ entries kind path = do
              kind @?= (workspaceCoordinate ("replace"))
              path @?= (workspaceCoordinate ("src/dependency.txt"))
              writeIORef checked (map (.text) entries)
              pure (Left "explicit operator policy conflict")
            authority = (runtime.authorizer) {Action.authorize = \principal action -> modifyIORef' authorizations (+ 1) >> allowAllActionAuthorizerForTests.authorize principal action}
            restricted = runtime & #admitTarget .~ targetPolicy & #authorizer .~ authority
        Executor.executeAcceptedAttempt (executorFor restricted (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readIORef checked >>= (@?= ["PRIVATE_ROOT_POLICY: validate before commit", "PRIVATE_NESTED_POLICY: scope source changes"])
        readIORef authorizations >>= (@?= 0)
        readFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt") >>= (@?= "old dependency\n"),
      testCase "contained reads return protected content hashes without changing the workspace" $ withEffectFor "read" Nothing fixture \env binding snapshot access reference runtime _ -> do
        let path = workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt"
        before <- getModificationTime path
        Executor.executeAcceptedAttempt (executorFor runtime (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        getModificationTime path >>= (@?= before)
        Just operation <- right =<< run env (Execution.inspectOperation reference.operationId)
        result <- maybe (fail "missing read outcome") pure operation.outcome
        output <- right =<< run env (Execution.readReplayPayload @OperationOutcome access "operation-outcome" result)
        assertBool "protected read outcome carries content and exact hash" (all (`Text.isInfixOf` Text.pack (show (Aeson.encode output))) ["old dependency", workspaceCoordinateText (contentDigest "old dependency\n")])
        run env (runTransaction (Store.checkWorkspaceOperationTx binding snapshot.identity (fixtureRevision 0) (fixtureOperationId "later"))) >>= (@?= Right ()),
      testCase "denied exact authority refuses before reserving or changing files" $ withEffect fixture \env binding snapshot _ reference runtime _ -> do
        Executor.executeAcceptedAttempt (executorFor (runtime & #authorizer .~ denyAllActionAuthorizer) (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt") >>= (@?= "old dependency\n")
        run env (runTransaction (Store.checkWorkspaceOperationTx binding snapshot.identity (fixtureRevision 0) (fixtureOperationId "later"))) >>= (@?= Right ()),
      testCase "an independently held workspace lock retains uncertainty without publishing" $ withEffect fixture \env binding snapshot access reference runtime _ -> do
        withWorkspaceLock
          (workspaceMetadata (workspaceLocatorPath binding.storageRoot) binding)
          ( do
              Executor.executeAcceptedAttempt (executorFor runtime (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
              pure (Right ())
          )
          >>= (@?= Right ())
        (_, state) <- right =<< run env (Execution.loadExecution access)
        state.phase @?= Unresolved
        state.cursor @?= (fixtureRevision 1)
        readFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt") >>= (@?= "old dependency\n"),
      testCase "historical workspace admission without file qualification refuses before IO" $ withEffectQualified (#filePolicy .~ Nothing) "replace" Nothing fixture \env binding snapshot _ reference runtime _ -> do
        Executor.executeAcceptedAttempt (executorFor runtime (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt") >>= (@?= "old dependency\n")
        run env (runTransaction (Store.checkWorkspaceOperationTx binding snapshot.identity (fixtureRevision 0) (fixtureOperationId "later"))) >>= (@?= Right ()),
      testCase "content conflicts and hostile accepted paths refuse without effects" $ do
        withEffect fixture \env binding snapshot _ reference runtime _ -> do
          let path = workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt"
          writeFile path "operator update\n"
          Executor.executeAcceptedAttempt (executorFor runtime (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          readFile path >>= (@?= "operator update\n")
          run env (runTransaction (Store.checkWorkspaceOperationTx binding snapshot.identity (fixtureRevision 0) (fixtureOperationId "later"))) >>= (@?= Right ())
        withEffectFor "replace" (Just (Aeson.toJSON (Replacement (workspaceCoordinate ("../escape")) Nothing "FORGED"))) fixture \_ binding snapshot _ reference runtime _ -> do
          Executor.executeAcceptedAttempt (executorFor runtime (pure ())) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          readFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt") >>= (@?= "old dependency\n"),
      testCase "substituted inputs and stale claim generations refuse before file IO" $ withEffect fixture \_ binding snapshot _ reference runtime input -> do
        let normal = executorFor runtime (pure ())
            protected =
              -- The rank-n capability field cannot be represented by Generic.
              normal
                { Executor.withTools = \accepted context requested use -> do
                    replaceWorkspaceFile runtime accepted (context & #generation .~ (Generation.advanceRevision context.generation)) input >>= (@?= Left FileEffectRefused)
                    replaceWorkspaceFile runtime accepted context (Aeson.toJSON (Replacement (workspaceCoordinate ("src/dependency.txt")) Nothing "FORGED")) >>= (@?= Left FileEffectRefused)
                    case normal of Executor.ExecutionRuntime {Executor.withTools = actual} -> actual accepted context requested use
                }
        Executor.executeAcceptedAttempt protected snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
        readFile (workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt") >>= (@?= "PRIVATE_REPLACEMENT\n")
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
withEffectAdapter = withEffectAdapterForTools 1

withEffectAdapterForTools :: Int -> (WorkspaceAdmission -> WorkspaceAdmission) -> (FileRuntime -> DurableAdapter) -> Text.Text -> Text.Text -> Maybe Aeson.Value -> DatabaseFixture -> (AppEnv -> WorkspaceBinding -> ExecutionSnapshot -> Execution.ReplayAccess -> Attempt.JobReference -> FileRuntime -> Aeson.Value -> IO a) -> IO a
withEffectAdapterForTools = withEffectAdapterPolicy Nothing

withEffectAdapterPolicy :: Maybe ProcessPolicy -> Int -> (WorkspaceAdmission -> WorkspaceAdmission) -> (FileRuntime -> DurableAdapter) -> Text.Text -> Text.Text -> Maybe Aeson.Value -> DatabaseFixture -> (AppEnv -> WorkspaceBinding -> ExecutionSnapshot -> Execution.ReplayAccess -> Attempt.JobReference -> FileRuntime -> Aeson.Value -> IO a) -> IO a
withEffectAdapterPolicy processPolicy toolCount qualify install wire logical supplied = withEffectAdapterPolicyInput processPolicy toolCount qualify install wire logical (const supplied)

withEffectAdapterPolicyInput :: Maybe ProcessPolicy -> Int -> (WorkspaceAdmission -> WorkspaceAdmission) -> (FileRuntime -> DurableAdapter) -> Text.Text -> Text.Text -> (WorkspaceBinding -> Maybe Aeson.Value) -> DatabaseFixture -> (AppEnv -> WorkspaceBinding -> ExecutionSnapshot -> Execution.ReplayAccess -> Attempt.JobReference -> FileRuntime -> Aeson.Value -> IO a) -> IO a
withEffectAdapterPolicyInput processPolicy toolCount qualify install wire logical supplied fixture use = Fixture.withFixture fixture \env source root _ -> do
  createDirectory (source </> "src")
  renameFile (source </> "dependency.txt") (source </> "src/dependency.txt")
  writeFile (source </> "AGENTS.md") "PRIVATE_ROOT_POLICY: validate before commit"
  writeFile (source </> "src/AGENTS.md") "PRIVATE_NESTED_POLICY: scope source changes"
  originalRepository <- Fixture.commitRepository source
  repository <- case processPolicy of
    Nothing -> pure originalRepository
    Just policy -> do
      let base = repositoryBase originalRepository
      catalog <- right (mkWorkspaceCatalog [RepositoryPolicy (repositoryIdentity originalRepository) (workspaceLocator source) [base] base (processPolicyIdentity policy)])
      right (resolveRepository catalog (repositoryIdentity originalRepository) Nothing)
  let identity = CompatibilityIdentity (fixtureAgentName "worker")
      rootId = fixtureRootId "file-root"
      request = WorkspaceRequest (WorkflowId "file-run") Nothing rootId identity identity (fixtureRevision 0)
      runtime = FileRuntime env allowAllActionAuthorizerForTests (const (pure (Right ()))) (const (pure (Right ()))) (\_ _ _ _ _ -> pure (Right ()))
      assignment = fixtureAssignment "file-execution"
  (binding, _) <- right =<< run env (runTransaction (Store.reserveWorkspaceTx root request repository))
  let input = maybe (if logical == "read" then Aeson.object ["path" .= ("src/dependency.txt" :: Text.Text)] else Aeson.toJSON (Replacement (workspaceCoordinate ("src/dependency.txt")) (Just (contentDigest "old dependency\n")) "PRIVATE_REPLACEMENT\n")) id (supplied binding)
  allocateWorkspace root binding Reserved >>= (@?= Right ())
  run env (runTransaction (Store.markWorkspaceReadyTx binding)) >>= (@?= Right ())
  admission <- qualify <$> (right =<< loadWorkspaceAdmission binding assignment 65536)
  now <- getCurrentTime
  _ <- right =<< run env Catalog.registerProjectionCatalog
  run env (Roots.enrollRoot rootId (Resources.Envelope (Map.fromList [(dimension, Resources.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now))) >>= (@?= Right Resources.Accepted)
  withAcceptedWorkspaceTool toolCount install (fixtureAgentName "worker") wire UUID.nil env admission runtime input \snapshot access reference -> use env binding snapshot access reference runtime input

-- Accept real model/tool state against an already allocated workspace. This
-- enables successive owners in one database without substituting dispatch ids.
withAcceptedWorkspaceTool :: Int -> (FileRuntime -> DurableAdapter) -> AgentName -> Text.Text -> UUID.UUID -> AppEnv -> WorkspaceAdmission -> FileRuntime -> Aeson.Value -> (ExecutionSnapshot -> Execution.ReplayAccess -> Attempt.JobReference -> IO a) -> IO a
withAcceptedWorkspaceTool toolCount install agent wire token env admission runtime input use = do
  let assignment = admission.assignmentId
      rootId = admission.rootId
      identity = admission.owner
  now <- getCurrentTime
  session <- genSessionId
  selection <- right (resolveExecutionSelection assignment (must (modelCatalog [])) (defaultBinding stubModel emptyOptions) Nothing Nothing Nothing Nothing (Just rootId) now)
  let adapter = install runtime
  registry <- right (installDurableAdapters [adapter] emptyCapabilityProviderRegistry)
  catalog <- right (mkCapabilityCatalog [adapter.descriptor])
  capabilities <- right (resolveGovernedCapabilityOverlays (durableAdapterInstalled registry) catalog (\_ _ -> Right ()) (ResolutionSubject (fmap declarationCoordinate ((Just (agentNameText agent)))) Durable (Skill (declarationCoordinate ("fixture"))) Nothing) [adapter.descriptor.capability])
  let initial = ExecutionSnapshot V1 (executionIdFor assignment) admission.runId agent identity session selection Nothing (SkillInstructions (ExecutionValue.executionCoordinate "fixture") "system" "body") (ReplayContext RequestContext (Just (instructionPrompt admission.instructions)) [RequestTurn [TextBlock "edit fixture"] Nothing]) capabilities (Aeson.toJSON ([] :: [Aeson.Value])) defaultHarnessPolicy [] (Just admission)
      native = Tools.NativeToolFactory (\_ -> pure (Right [])) (\_ _ _ -> pure (Right []))
  menu <- right =<< Tools.describeExecutionTools Log.silentLogger allowAllActionAuthorizerForTests registry native initial
  let chosen = filter (\tool -> executionCoordinateText tool.name == wire) menu.toolBindings
      tool = case chosen of [value] -> value; _ -> error "missing fixture file binding"
      snapshot = initial & #offeredTools .~ Aeson.toJSON (filterTools menu.offeredTools) & #toolBindings .~ [tool]
      model = OperationSpec (operationIdFor snapshot.executionId (fixtureRevision 0)) ModelTurn RepeatableObservation (ExecutionValue.executionCoordinate "model") (ExecutionValue.executionDigestFor "shikigami.harness-policy/1" (Aeson.toJSON snapshot.policy)) (ExecutionValue.executionDigest "scope") Nothing
  _ <- right =<< run env Catalog.registerProjectionCatalog
  run env (Execution.admitExecution snapshot) >>= (@?= Right Resources.Accepted)
  access <- right =<< run env (Execution.authorizeReplay snapshot.executionId identity (pure (Right ())))
  (_, operation) <- right =<< run env (Execution.acceptOperation access (fixtureRevision 0) model (Aeson.object []))
  let operationKey = operationIdText operation.specification.operationId
      modelRequest = Resources.AttemptRequest (fixtureAttemptId ("model:" <> operationKey)) operation.specification.operationId (Map.fromList [(Resources.ActiveWork, (fixtureAmount 1)), (Resources.ModelAttempts, (fixtureAmount 1)), (Resources.Tokens, (fixtureAmount 10)), (Resources.CostMicroUsd, (fixtureAmount 0))]) Resources.EnforcedCeiling
  reservation <- right =<< run env (Calls.reserveSelectionCall selection (Calls.CallLimits Nothing Nothing Nothing Nothing Nothing) modelRequest (ExecutionValue.executionDigest "fixture-model") now)
  call <- case reservation of Calls.NewCall value -> pure value; _ -> fail "new fixture call required"
  let assistant = ReplayAssistant V1 ([ToolBlock (ToolInvocation (ProviderValue.providerCoordinate "replace-call") tool.name input)] <> [ToolBlock (ToolInvocation (ProviderValue.providerCoordinate ("additional-call-" <> Text.pack (show index))) tool.name input) | index <- [1 .. toolCount - 1]]) ToolUse Nothing Nothing (Aeson.object []) Nothing
      outcome = ModelReturned assistant Nothing
  response <- right (Execution.outcomeReference outcome)
  run env (Execution.recordOutcomeAndAdvance access (fixtureRevision 1) operation.specification.operationId outcome (NeedTool response (fixtureToolPosition 0)) (Just (call, Calls.CallOutcome Calls.CallTerminal (Map.singleton Resources.Tokens (fixtureAmount 1)) [Resources.CostMicroUsd] Nothing Nothing Nothing))) >>= (@?= Right Resources.Accepted)
  let toolInput = ToolOperationInput response (fixtureToolPosition 0) (ToolInvocation (ProviderValue.providerCoordinate "replace-call") tool.name input) tool
      specification = OperationSpec (operationIdFor snapshot.executionId (fixtureRevision 1)) ToolOperation tool.recovery tool.name (ExecutionValue.executionDigestFor "shikigami.harness-policy/1" (Aeson.toJSON snapshot.policy)) (toolScopeDigest tool) (Just (fixtureToolPosition 0))
      reference = Attempt.JobReference V1 snapshot.executionId specification.operationId (fixtureAttemptId ("file-tool:" <> operationIdText (specification.operationId)))
      submission = Attempt.AttemptSubmission (Execution.toolAttemptRequest reference.attemptId reference.operationId tool) Nothing (Attempt.ExecutionWake (AwakeableId token) ExecutionValue.initialExecutionGeneration)
  _ <- right =<< run env (Execution.acceptOperation access (fixtureRevision 2) specification (Aeson.toJSON toolInput))
  run env (runTransaction (registerAwakeableTx token "shikigami.execution" (executionWorkflowId snapshot.executionId).unWorkflowId))
  _ <- right =<< run env (Execution.submitExecutionAttemptWith access (fixtureRevision 3) submission (\_ -> pure ()))
  use snapshot access reference
  where
    filterTools (Aeson.Array values) = Aeson.Array (filterVector values)
    filterTools value = value
    filterVector = DataVector.filter (\value -> case value of Aeson.Object fields -> AesonKeyMap.lookup "name" fields == Just (Aeson.String wire); _ -> False)

executorFor :: FileRuntime -> IO () -> Executor.ExecutionRuntime
executorFor runtime checkpoint = executorForAdapter (workspaceEditAdapterWithCheckpoint checkpoint) runtime

executorForAdapter :: (FileRuntime -> DurableAdapter) -> FileRuntime -> Executor.ExecutionRuntime
executorForAdapter install runtime = Executor.ExecutionRuntime runtime.appEnv (const (pure (Right ()))) runtime.lifecycle (\_ -> error "fixture never dispatches a model") (Tools.withExecutionTools Log.silentLogger runtime.authorizer registry native) ((either (error . show) id . parseDuration) (5))
  where
    registry = must (installDurableAdapters [install runtime] emptyCapabilityProviderRegistry)
    native = Tools.NativeToolFactory (\_ -> pure (Right [])) (\_ _ _ -> pure (Right []))

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

must :: (Show e) => Either e a -> a
must = either (error . show) id

-- Supplies database readiness only. Native account/ownership qualification is
-- separate; these tests use the actual accepted file adapter and claim stores.
withSupervisedEffect :: DatabaseFixture -> (ProcessPolicy -> ProcessPolicy) -> Text.Text -> (AppEnv -> WorkspaceBinding -> ExecutionSnapshot -> Attempt.JobReference -> FileRuntime -> ProcessProfile -> IO a) -> IO a
withSupervisedEffect fixture change logical use = do
  properties <- Systemd.systemdPropertiesIdentity
  let digest = "sha256:" <> Text.replicate 64 "a"
      policy = change (ProcessPolicy ProcessPolicyV1 (ProcessImage (workspaceLocator "/qualified/root") (workspaceCoordinate (digest)) (workspaceLocator "/bin/env") (workspaceLocator "/bin/deadline") (workspaceLocator "/qualified/collector")) properties [CommandRule (workspaceCoordinate "validate") (workspaceCoordinate "/bin/validate") [] (workspaceCoordinate "") Map.empty ((either (error . show) id . parseProcessSeconds) 30) ((either (error . show) id . parseProcessOutputBytes) 1024)] [(workspaceCoordinate "")] [(workspaceCoordinate "src")])
  withEffectAdapterPolicy (Just policy) 1 (\admission -> admission & #filePolicy .~ Just supervisedFilePolicy) supervisedWorkspaceEditAdapter ("overlay__workspace-edit__" <> logical) logical Nothing fixture \env binding snapshot _ reference runtime _ -> do
    admission <- maybe (fail "workspace admission missing") pure snapshot.workspace
    (profile, _) <- right =<< run env (runTransaction (reserveProcessProfileTx binding (bundleDigest admission.instructions) policy (IdentityRange ((either (error . show) id . parseWorkspaceIdentity) 62000) ((either (error . show) id . parseWorkspaceIdentity) 62001))))
    use env binding snapshot reference runtime profile

retainedOutput :: AppEnv -> ExecutionSnapshot -> Operation -> IO OperationOutcome
retainedOutput env snapshot operation = do
  access <- right =<< run env (Execution.authorizeReplay snapshot.executionId snapshot.identity (pure (Right ())))
  result <- maybe (fail "missing file outcome") pure operation.outcome
  right =<< run env (Execution.readReplayPayload @OperationOutcome access "operation-outcome" result)

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureAmount :: Integer -> ResourceAmount
fixtureAmount amount = either (error . show) id (parseResourceAmount amount)

fixtureCount :: Integer -> AttemptCount scope
fixtureCount count = either (error . show) id (parseAttemptCount count)

fixtureProgress :: (ProgressNumber a) => Integer -> a
fixtureProgress number = either (error . show) id (parseProgress number)

fixtureToolPosition :: Integer -> ToolPosition
fixtureToolPosition value = either (error . show) id (parseToolPosition value)

fixtureAssignment :: AssignmentText.Text -> AssignmentKey
fixtureAssignment = either (error . show) id . parseAssignmentKey

fixtureGeneration :: Integer -> Generation.StateRevision "execution-attempt"
fixtureGeneration value = either (error . show) id (Generation.parseRevision value)

fixtureOwner :: ClaimText.Text -> Claim.ClaimOwner
fixtureOwner value = either (error . show) id (Claim.parseClaimOwner value)

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

corruptRegisteredFile :: DatabaseFixture -> IO ()
corruptRegisteredFile fixture = withEffect fixture \env binding snapshot access reference runtime _ -> do
  Executor.executeAcceptedAttempt (executorFor runtime (throwIO (userError "lost publication acknowledgement"))) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
  Just original <- right =<< run env (runTransaction (Store.inspectRegisteredFileTx reference.operationId))
  let (_, registration, _) = original
      file = workspaceFiles (workspaceLocatorPath binding.storageRoot) binding </> "src/dependency.txt"
      replace value = run env (runTransaction (Tx.statement value (preparable "UPDATE shikigami.workspace_file_registrations SET registration=$1" (E.param (E.nonNullable E.jsonb)) D.noResult)))
  published <- getModificationTime file
  (_, before) <- right =<< run env (Execution.loadExecution access)
  before.phase @?= Unresolved
  mapM_
    ( \value -> do
        replace value
        run env (runTransaction (Store.inspectRegisteredFileTx reference.operationId)) >>= (@?= Left WorkspaceBindingConflict)
        ignored <-
          run
            env
            ( runTransaction do
                _ <- Store.freezeWorkspaceTx binding snapshot.identity (fixtureRevision 0)
                Store.inspectRegisteredFileTx reference.operationId
            )
        ignored @?= Left WorkspaceBindingConflict
        control <- right =<< run env (runTransaction (Store.inspectWorkspaceControlTx binding))
        fmap Store.workspaceFrozen control @?= Just False
        publishFileReceipt env reference.operationId >>= (@?= Left FileEffectUnresolved)
        (_, after) <- right =<< run env (Execution.loadExecution access)
        after @?= before
        getModificationTime file >>= (@?= published)
        replace (Aeson.toJSON registration)
    )
    [Aeson.Null, Aeson.toJSON (registration & #receipt . #fingerprint .~ (workspaceCoordinate ("different-retained-intent"))), Aeson.toJSON (registration & #receipt . #generation .~ fixtureRevision 0), Aeson.toJSON (registration & #receipt . #path .~ (workspaceCoordinate ("../outside")))]
  run env (runTransaction (Store.inspectRegisteredFileTx reference.operationId)) >>= (@?= Right (Just original))
  publishFileReceipt env reference.operationId >>= (@?= Right FileReceiptAcknowledged)
  publishFileReceipt env reference.operationId >>= (@?= Right FileReceiptAcknowledged)
  getModificationTime file >>= (@?= published)
  readFile file >>= (@?= "PRIVATE_REPLACEMENT\n")
