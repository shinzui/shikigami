{-# LANGUAGE DataKinds #-}

module Shikigami.WorkspaceTransferSpec (tests) where

import Baikai.Options (emptyOptions)
import Control.Concurrent.Async (withAsync)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as ClaimText
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Data.UUID.V4 qualified as UUID4
import Effectful (Eff)
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.Id (genSessionId)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization
import Shikigami.Agent.Decl (defaultDelegationBudget)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Delegate.Depth (DelegationDepth, parseDelegationDepth)
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Behavior.Skill (SkillDir (..))
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Capability.Overlay (emptyResolvedCapabilitySet)
import Shikigami.Decision.ModelCatalog (modelCatalog)
import Shikigami.Execution.Attempt (JobReference (..))
import Shikigami.Execution.Claim qualified as Claim
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Identity (AttemptId, ExecutionRootId, OperationId)
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Selection
import Shikigami.Execution.SelectionRuntime qualified as Selection
import Shikigami.Execution.Start (SkillAssignment (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript
import Shikigami.Fixture.ExecutionIdentity (fixtureAttemptId, fixtureOperationId, fixtureRootId)
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude hiding ((.=))
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.StateRevision (StateRevision, advanceRevision, parseRevision)
import Shikigami.StateRevision qualified as Generation
import Shikigami.WorkerSession.Checkpoint (ObjectiveVersion (..))
import Shikigami.WorkerSession.Input (InstructionText, SessionLimit (..), parseInstructionText)
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Transfer
import Shikigami.WorkerSession.Types hiding (assignmentIdFor)
import Shikigami.Workspace.Admission (WorkspaceHost (..))
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.CleanupStore (cleanupEligibleTx, listWorkspacesTx)
import Shikigami.Workspace.ContainedFile (ensurePrivateDirectory, withWorkspaceLock)
import Shikigami.Workspace.FileProvider
import Shikigami.Workspace.Host
import Shikigami.Workspace.InstructionLoader
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.ProcessProfileStore
import Shikigami.Workspace.ProcessProvider (ProcessClient (..))
import Shikigami.Workspace.ProcessStore qualified as Processes
import Shikigami.Workspace.Provider (FileReceipt (..), ReceiptState (..))
import Shikigami.Workspace.Rpc
import Shikigami.Workspace.Store qualified as Workspaces
import Shikigami.Workspace.Supervisor
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.Transfer
import Shikigami.Workspace.TransferClient
import Shikigami.Workspace.TransferStore qualified as Transfers
import Shikigami.Workspace.Types
import Shikigami.WorkspaceFileProviderSpec qualified as FileFixture
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
    [ testCase "same-owner follow-up reuses retained bytes and unknown effects prevent a fresh-copy fallback" $ do
        properties <- Systemd.systemdPropertiesIdentity
        let digest = "sha256:" <> Text.replicate 64 "a"
            policy = ProcessPolicy 1 (ProcessImage "/qualified/root" digest "/bin/env" "/bin/deadline" "/qualified/collector") properties [CommandRule "validate" "/bin/validate" [] "" Map.empty 30 1024] [""] [""]
        withWorkspacePolicy False (Just policy) fixture \env binding context _ _ -> do
          original <- (\admission -> admission & #filePolicy .~ Just transferableFilePolicy) <$> (right =<< loadWorkspaceAdmission binding (Selection.assignmentIdFor binding.request.runId) 65536)
          (profile, _) <- right =<< run env (runTransaction (reserveProcessProfileTx binding (bundleDigest original.instructions) policy (IdentityRange 62000 62001)))
          run env (runTransaction (readyProcessProfileTx binding profile)) >>= (@?= Right ())
          let runtime = FileRuntime env allowAllActionAuthorizerForTests (const (pure (Right ()))) (const (pure (Right ()))) (\_ _ _ _ _ -> pure (Right ()))
              input = Aeson.object ["path" .= ("dependency.txt" :: Text)]
          token <- UUID4.nextRandom
          execution <- FileFixture.withAcceptedWorkspaceTool 1 transferredWorkspaceEditAdapter (fixtureAgentName "worker") "overlay__workspace-edit__read" token env original runtime input \snapshot access reference -> do
            Executor.executeAcceptedAttempt (FileFixture.executorForAdapter transferredWorkspaceEditAdapter runtime) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
            (_, state) <- right =<< run env (Execution.loadExecution access)
            _ <- right =<< run env (Execution.stopExecution snapshot.identity snapshot.executionId state.revision StopAsFailure (ExecutionPolicyRefused "fixture terminal"))
            pure snapshot.executionId
          parent <- right =<< run env (Sessions.authorizeSession context.sessionId context.actor (pure (Right ())))
          Just (_, first) <- pure binding.request.assignment
          Just (active, _) <- right =<< run env (Sessions.inspectSession context.sessionId)
          _ <- right =<< run env (Sessions.recordResult parent active.revision (fixtureRevision 0) (fixtureOperationId "finish-first") (AssignmentResult 1 first AssignmentFailed (Just execution) Aeson.Null []))
          Just (idle, _) <- right =<< run env (Sessions.inspectSession context.sessionId)
          (_, message) <- right =<< run env (Sessions.acceptMessage parent idle.revision (fixtureRevision 0) (fixtureOperationId "follow-up") (Instruction 1 FollowUp (fixtureInstruction "continue accepted work") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing))
          (_, started) <- right =<< run env (Sessions.startAssignment parent (advanceRevision idle.revision) (fixtureRevision 0) (fixtureOperationId "start-follow-up") message.assignmentId)
          child <- maybe (fail "missing follow-up child") pure started.childWorkflowId
          now <- getCurrentTime
          memory <- genSessionId
          selection <- right (resolveExecutionSelection (Selection.assignmentIdFor child) (either (error . show) id (modelCatalog [])) (defaultBinding stubModel emptyOptions) Nothing Nothing Nothing Nothing (Just context.rootId) now)
          let assignment = SkillAssignment child (fixtureAgentName "worker") binding.request.owner memory selection Nothing emptyResolvedCapabilitySet (Right defaultHarnessPolicy) (SkillDir "fixture") (fail "host cannot dispatch models")
          catalog <- right (mkWorkspaceCatalog [RepositoryPolicy binding.repository binding.source [binding.base] binding.base binding.policyRevision])
          repository <- right (resolveRepository catalog binding.repository Nothing)
          host <- right (governedWorkspaceHostWithTransfers runtime [transferredWorkspaceEditAdapter runtime] [] (\_ _ admission -> pure (Right admission)) binding.storageRoot (const (pure (Right repository))) (const (pure (Right ()))))
          -- This fixture datum stands for retained accepted work; native owned
          -- writes remain qualified separately by the Linux handoff fixture.
          writeFile (workspaceFiles binding.storageRoot binding </> "dependency.txt") "ACCEPTED_PRIOR_CHANGE\n"
          let operation = fixtureOperationId "uncertain-prior-effect"
              prepared = FileReceipt operation (fixtureAttemptId "prior-actual") (fixtureGeneration 1) digest (workspaceBindingDigest binding) (bundleDigest original.instructions) "dependency.txt" "1:2" Nothing digest EditPrepared
          _ <- right =<< run env (runTransaction (Workspaces.reserveWorkspaceEffectTx binding binding.request.owner (fixtureRevision 0) operation digest))
          run env (runTransaction (Workspaces.recordWorkspaceReceiptTx binding prepared)) >>= (@?= Right ())
          host.load assignment >>= \case Left _ -> pure (); Right _ -> assertFailure "unknown effect was bypassed"
          length <$> run env (runTransaction (listWorkspacesTx binding.storageRoot Nothing)) >>= (@?= 1)
          run env (runTransaction (Workspaces.recordWorkspaceReceiptTx binding (prepared & #state .~ EditRefused))) >>= (@?= Right ())
          admission <- right =<< host.load assignment
          admission.workspace @?= binding.workspace
          admission.owner @?= binding.request.owner
          admission.epoch @?= (fixtureRevision 0)
          host.load assignment >>= (@?= Right admission)
          nextToken <- UUID4.nextRandom
          latest <- FileFixture.withAcceptedWorkspaceTool 1 transferredWorkspaceEditAdapter (fixtureAgentName "worker") "overlay__workspace-edit__read" nextToken env admission runtime input \snapshot access reference -> do
            Executor.executeAcceptedAttempt (FileFixture.executorForAdapter transferredWorkspaceEditAdapter runtime) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
            Just operation <- right =<< run env (Execution.inspectOperation reference.operationId)
            result <- maybe (fail "missing follow-up result") pure operation.outcome
            output <- right =<< run env (Execution.readReplayPayload @OperationOutcome access "operation-outcome" result)
            assertBool "follow-up sees accepted work" ("ACCEPTED_PRIOR_CHANGE" `Text.isInfixOf` Text.pack (show (Aeson.encode output)))
            Just (active, _) <- right =<< run env (Sessions.inspectSession context.sessionId)
            _ <- right =<< run env (Sessions.recordResult parent active.revision (fixtureRevision 0) (fixtureOperationId "premature-second-result") (AssignmentResult 1 message.assignmentId AssignmentFailed (Just snapshot.executionId) Aeson.Null []))
            Just (idle, _) <- right =<< run env (Sessions.inspectSession context.sessionId)
            (_, third) <- right =<< run env (Sessions.acceptMessage parent idle.revision (fixtureRevision 0) (fixtureOperationId "third-message") (Instruction 1 FollowUp (fixtureInstruction "continue again") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing))
            (_, started) <- right =<< run env (Sessions.startAssignment parent (advanceRevision idle.revision) (fixtureRevision 0) (fixtureOperationId "third-start") third.assignmentId)
            thirdRun <- maybe (fail "missing third child") pure started.childWorkflowId
            selection <- right (resolveExecutionSelection (Selection.assignmentIdFor thirdRun) (either (error . show) id (modelCatalog [])) (defaultBinding stubModel emptyOptions) Nothing Nothing Nothing Nothing (Just context.rootId) now)
            let next = assignment & #runId .~ thirdRun & #selection .~ selection
            host.load next >>= \case Left _ -> pure (); Right _ -> assertFailure "a session result hid an active prior execution"
            (_, state) <- right =<< run env (Execution.loadExecution access)
            _ <- right =<< run env (Execution.stopExecution snapshot.identity snapshot.executionId state.revision StopAsFailure (ExecutionPolicyRefused "fixture terminal"))
            resumed <- right =<< host.load next
            resumed.workspace @?= binding.workspace
            pure thirdRun
          effective <- run env (runTransaction (Transfers.currentWorkspaceRequestTx binding))
          fmap (.runId) effective @?= Just latest
          run env (runTransaction (inspectProcessProfileTx binding.workspace)) >>= (@?= Just (profile, ProfileReady)),
      testCase "successor host admits the real retained child and exact read adapter without reallocating or provisioning" $ do
        properties <- Systemd.systemdPropertiesIdentity
        let digest = "sha256:" <> Text.replicate 64 "a"
            policy = ProcessPolicy 1 (ProcessImage "/qualified/root" digest "/bin/env" "/bin/deadline" "/qualified/collector") properties [CommandRule "validate" "/bin/validate" [] "" Map.empty 30 1024] [""] [""]
        withTransferPolicy (Just policy) fixture \env binding intent supervisor _ -> do
          original <- right =<< loadWorkspaceAdmission binding (Selection.assignmentIdFor binding.request.runId) 65536
          (profile, _) <- right =<< run env (runTransaction (reserveProcessProfileTx binding (bundleDigest original.instructions) policy (IdentityRange 62000 62001)))
          run env (runTransaction (readyProcessProfileTx binding profile)) >>= (@?= Right ())
          -- Mutable instruction proposals cannot replace the pinned base.
          writeFile (workspaceFiles binding.storageRoot binding </> "AGENTS.md") "MUTABLE_POLICY_PROPOSAL"
          FencedAndSettled proof <- (workspaceTransferProvider supervisor).reconcile intent
          childRun <- establishSuccessor env binding intent proof
          session <- genSessionId
          now <- getCurrentTime
          selection <- right (resolveExecutionSelection (Selection.assignmentIdFor childRun) (either (error . show) id (modelCatalog [])) (defaultBinding stubModel emptyOptions) Nothing Nothing Nothing Nothing (Just intent.rootId) now)
          let fileRuntime = FileRuntime env allowAllActionAuthorizerForTests (const (pure (Right ()))) (const (pure (Right ()))) (\_ admission _ kind _ -> pure (if kind == "admit" && map (.text) (bundleFiles admission.instructions) /= ["PINNED_ROOT_POLICY: validate before committing"] then Left "changed instruction identity" else Right ()))
              assignment = SkillAssignment childRun intent.newWorker intent.newOwner session selection Nothing emptyResolvedCapabilitySet (Right defaultHarnessPolicy) (SkillDir "fixture") (fail "host loading cannot call a model")
          catalog <- right (mkWorkspaceCatalog [RepositoryPolicy binding.repository binding.source [binding.base] binding.base binding.policyRevision])
          repository <- right (resolveRepository catalog binding.repository Nothing)
          let hostFor runtime = right (governedWorkspaceHostWithTransfers runtime [transferredWorkspaceEditAdapter runtime] [workspaceEditAdapter runtime, supervisedWorkspaceEditAdapter runtime] (\_ _ admission -> pure (Right admission)) binding.storageRoot (const (pure (Right repository))) (const (pure (Right ()))))
          denied <- hostFor (fileRuntime & #authorizer .~ denyAllActionAuthorizer)
          denied.load assignment >>= \case Left _ -> pure (); Right _ -> assertFailure "denied successor admitted"
          run env (runTransaction (Workspaces.checkWorkspaceOwnerTx binding intent.newOwner (fixtureRevision 1))) >>= (@?= Left WorkspaceBindingConflict)
          host <- hostFor fileRuntime
          admission <- right =<< host.load assignment
          admission.owner @?= intent.newOwner
          admission.epoch @?= (fixtureRevision 1)
          admission.runId @?= childRun
          admission.filePolicy @?= Just transferableFilePolicy
          host.load assignment >>= (@?= Right admission)
          token <- UUID4.nextRandom
          FileFixture.withAcceptedWorkspaceTool 1 transferredWorkspaceEditAdapter intent.newWorker "overlay__workspace-edit__read" token env admission fileRuntime (Aeson.object ["path" .= ("dependency.txt" :: Text)]) \snapshot access reference -> do
            Executor.executeAcceptedAttempt (FileFixture.executorForAdapter transferredWorkspaceEditAdapter fileRuntime) snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
            (_, state) <- right =<< run env (Execution.loadExecution access)
            state.cursor @?= (fixtureRevision 2)
            Just operation <- right =<< run env (Execution.inspectOperation reference.operationId)
            result <- maybe (fail "missing successor result") pure operation.outcome
            output <- right =<< run env (Execution.readReplayPayload @OperationOutcome access "operation-outcome" result)
            assertBool "successor reads retained accepted bytes" ("old dependency" `Text.isInfixOf` Text.pack (show (Aeson.encode output)))
            parent <- right =<< run env (Sessions.authorizeSession intent.sessionId intent.actor (pure (Right ())))
            Just (active, _) <- right =<< run env (Sessions.inspectSession intent.sessionId)
            assignment <- maybe (fail "missing successor assignment") pure active.activeAssignment
            _ <- right =<< run env (Sessions.recordResult parent active.revision (fixtureRevision 1) (fixtureOperationId "finish-successor") (AssignmentResult 1 assignment AssignmentFailed (Just snapshot.executionId) Aeson.Null []))
            -- Idleness never retires the continuing session's workspace. Once
            -- closed, eligibility follows the successor execution, despite no
            -- terminal original-allocation execution being present.
            run env (runTransaction (cleanupEligibleTx binding)) >>= (@?= False)
            Just (idle, _) <- right =<< run env (Sessions.inspectSession intent.sessionId)
            (_, nextMessage) <- right =<< run env (Sessions.acceptMessage parent idle.revision (fixtureRevision 1) (fixtureOperationId "successor-followup-message") (Instruction 1 FollowUp (fixtureInstruction "continue successor") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing))
            (_, nextStarted) <- right =<< run env (Sessions.startAssignment parent (advanceRevision idle.revision) (fixtureRevision 1) (fixtureOperationId "successor-followup-start") nextMessage.assignmentId)
            nextRun <- maybe (fail "missing successor followup child") pure nextStarted.childWorkflowId
            nextSelection <- right (resolveExecutionSelection (Selection.assignmentIdFor nextRun) (either (error . show) id (modelCatalog [])) (defaultBinding stubModel emptyOptions) Nothing Nothing Nothing Nothing (Just intent.rootId) now)
            let nextAssignment = assignmentFor nextRun nextSelection
                assignmentFor run selected = SkillAssignment run intent.newWorker intent.newOwner session selected Nothing emptyResolvedCapabilitySet (Right defaultHarnessPolicy) (SkillDir "fixture") (fail "host cannot call models")
            host.load nextAssignment >>= \case Left _ -> pure (); Right _ -> assertFailure "live prior successor execution admitted followup"
            _ <- right =<< run env (Execution.stopExecution snapshot.identity snapshot.executionId state.revision StopAsFailure (ExecutionPolicyRefused "fixture terminal"))
            nextAdmission <- right =<< host.load nextAssignment
            nextToken <- UUID4.nextRandom
            FileFixture.withAcceptedWorkspaceTool 1 transferredWorkspaceEditAdapter intent.newWorker "overlay__workspace-edit__read" nextToken env nextAdmission fileRuntime (Aeson.object ["path" .= ("dependency.txt" :: Text)]) \nextSnapshot nextAccess nextReference -> do
              Executor.executeAcceptedAttempt (FileFixture.executorForAdapter transferredWorkspaceEditAdapter fileRuntime) nextSnapshot.identity nextReference >>= (@?= Right Executor.ExecutorDone)
              (_, nextState) <- right =<< run env (Execution.loadExecution nextAccess)
              _ <- right =<< run env (Execution.stopExecution nextSnapshot.identity nextSnapshot.executionId nextState.revision StopAsFailure (ExecutionPolicyRefused "fixture terminal"))
              Just (running, _) <- right =<< run env (Sessions.inspectSession intent.sessionId)
              _ <- right =<< run env (Sessions.recordResult parent running.revision (fixtureRevision 1) (fixtureOperationId "finish-successor-followup") (AssignmentResult 1 nextMessage.assignmentId AssignmentFailed (Just nextSnapshot.executionId) Aeson.Null []))
              pure ()
            Just (finished, _) <- right =<< run env (Sessions.inspectSession intent.sessionId)
            _ <- right =<< run env (Sessions.closeSession parent finished.revision (fixtureRevision 1) (fixtureOperationId "close-successor") AssignmentFailed)
            run env (runTransaction (cleanupEligibleTx binding)) >>= (@?= True)
          run env (runTransaction (Workspaces.inspectWorkspaceTx binding.workspace)) >>= (@?= Just (binding, Ready))
          run env (runTransaction (inspectProcessProfileTx binding.workspace)) >>= (@?= Just (profile, ProfileReady))
          (workspaceTransferProvider supervisor).admitWrite binding.workspace intent.sessionId intent.oldOwner (fixtureRevision 0) (fixtureOperationId "late-original") >>= assertRefused,
      testCase "private peer client recovers one retained fence across service restart and revocation" $ withTransfer fixture \env binding intent runtime _ -> withListener \path listener uid -> do
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
          client.admitWrite binding.workspace intent.sessionId intent.oldOwner (fixtureRevision 0) (fixtureOperationId "late-old") >>= assertRefused
          client.admitWrite binding.workspace intent.sessionId intent.newOwner (fixtureRevision 1) (fixtureOperationId "premature-successor") >>= assertRefused
        run env (runTransaction (Workspaces.inspectWorkspaceTx binding.workspace)) >>= (@?= Just (binding, Ready)),
      testCase "freeze cancels the retained process but cannot prove descendant settlement from a stop request" $ withTransferProcess fixture \env binding intent runtime record stopped -> do
        provider <- pure (workspaceTransferProvider runtime)
        provider.reconcile intent >>= (@?= FenceUnresolved)
        readIORef stopped >>= (@?= 1)
        doesFileExist (processDirectory binding record </> "cancel") >>= (@?= True)
        readFile (workspaceFiles binding.storageRoot binding </> "dependency.txt") >>= (@?= "old dependency\n")
        provider.admitWrite binding.workspace intent.sessionId intent.newOwner (fixtureRevision 1) (fixtureOperationId "premature") >>= assertRefused
        -- Instrumented factual backend evidence, not a real process qualification.
        let empty = CapturedOutput "stdout" ("sha256:" <> Text.replicate 64 "b") 0 False
            receipt = ProcessReceipt record.operationId record.attemptId record.generation record.fingerprint record.bindingDigest record.unit boot invocation (Just 143) ProcessCancelled empty (empty & #artifact .~ "stderr") True True
        run env (runTransaction (Processes.recordProcessReceiptTx receipt)) >>= (@?= Right ())
        outcome <- (workspaceTransferProvider (runtime & #authorizer .~ denyAllActionAuthorizer)).reconcile intent
        assertBool "only retained full settlement produces a fence" (case outcome of FencedAndSettled proof -> matchesFence intent proof; _ -> False)
        provider.admitWrite binding.workspace intent.sessionId intent.oldOwner (fixtureRevision 0) (fixtureOperationId "late-old") >>= assertRefused,
      testCase "a reserved process is refused without launch while unknown launch evidence remains pending" $ withTransfer fixture \env binding intent runtime _ -> do
        record <- reserveProcess env binding
        (workspaceTransferProvider runtime).reconcile intent >>= \outcome -> assertBool "proven unlaunched reservation permits settlement" (case outcome of FencedAndSettled proof -> matchesFence intent proof; _ -> False)
        Just retained <- run env (runTransaction (Processes.inspectProcessTx record.operationId))
        retained.phase @?= ProcessRefused,
      testCase "denied fresh authority never freezes or stops an unadmitted workspace" $ withTransferProcess fixture \env binding intent runtime _ stopped -> do
        (workspaceTransferProvider (runtime & #authorizer .~ denyAllActionAuthorizer)).reconcile intent >>= (@?= FenceUnavailable)
        readIORef stopped >>= (@?= 0)
        run env (runTransaction (Workspaces.checkWorkspaceOwnerTx binding intent.oldOwner (fixtureRevision 0))) >>= (@?= Right ()),
      testCase "an independently held writer lock cannot be mistaken for successful write or fence admission" $ withTransfer fixture \_ binding intent runtime _ -> do
        withWorkspaceLock
          (workspaceMetadata binding.storageRoot binding)
          ( do
              (workspaceTransferProvider runtime).reconcile intent >>= (@?= FenceUnresolved)
              (workspaceTransferProvider runtime).admitWrite binding.workspace intent.sessionId intent.oldOwner (fixtureRevision 0) (fixtureOperationId "locked-write") >>= assertRefused
              pure (Right ())
          )
          >>= (@?= Right ())
    ]

boot, invocation :: Text
boot = "11111111-1111-4111-8111-111111111111"
invocation = "22222222-2222-4222-8222-222222222222"

withTransfer :: DatabaseFixture -> (AppEnv -> WorkspaceBinding -> TransferIntent -> SupervisorRuntime -> IORef Int -> IO a) -> IO a
withTransfer = withTransferPolicy Nothing

withTransferPolicy :: Maybe ProcessPolicy -> DatabaseFixture -> (AppEnv -> WorkspaceBinding -> TransferIntent -> SupervisorRuntime -> IORef Int -> IO a) -> IO a
withTransferPolicy = withWorkspacePolicy True

withWorkspacePolicy :: Bool -> Maybe ProcessPolicy -> DatabaseFixture -> (AppEnv -> WorkspaceBinding -> TransferIntent -> SupervisorRuntime -> IORef Int -> IO a) -> IO a
withWorkspacePolicy transferring policy fixture callback = Fixture.withFixture fixture \env source storage originalRepository -> do
  repository <- case policy of
    Nothing -> pure originalRepository
    Just selected -> do
      writeFile (source </> "AGENTS.md") "PINNED_ROOT_POLICY: validate before committing"
      original <- Fixture.commitRepository source
      let base = repositoryBase original
      catalog <- right (mkWorkspaceCatalog [RepositoryPolicy (repositoryIdentity original) source [base] base (processPolicyIdentity selected)])
      right (resolveRepository catalog (repositoryIdentity original) Nothing)
  now <- getCurrentTime
  parentSession <- genSessionId
  parent <- right =<< loadAgent "../agents/heartbeat.dhall"
  let root = fixtureRootId "transfer-root"
      old = compatibilityIdentity (fixtureAgentName "worker")
      successor = compatibilityIdentity (fixtureAgentName "successor")
      actor = compatibilityIdentity (fixtureAgentName "coordinator")
      session = SessionAdmission 1 (SessionScope "fixture-parent" "worker") (ObjectiveRef "fixture-checkpoints" "objective") (parent & #name .~ fixtureAgentName "coordinator" & #delegates .~ map fixtureAgentName ["worker", "successor"]) (DelegateCtx (fixtureDelegationDepth 0) actor (Just parentSession) Nothing (Just (WorkflowId "parent")) [fixtureAgentName "coordinator"] Nothing (Just root) Nothing defaultDelegationBudget) (fixtureAgentName "worker") old (fixtureLimit 10) (fixtureLimit 4)
  _ <- right =<< run env Catalog.registerProjectionCatalog
  run env (Roots.enrollRoot root (Resources.Envelope (Map.fromList [(dimension, Resources.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now))) >>= (@?= Right Resources.Accepted)
  _ <- right =<< run env (Sessions.openSession session)
  access <- right =<< run env (Sessions.authorizeSession (sessionIdFor session) actor (pure (Right ())))
  (_, message) <- right =<< run env (Sessions.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (fixtureOperationId "send") (Instruction 1 FollowUp (fixtureInstruction "fixture") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing))
  (_, started) <- right =<< run env (Sessions.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (fixtureOperationId "start") message.assignmentId)
  child <- maybe (fail "missing child") pure started.childWorkflowId
  (binding, _) <- right =<< run env (runTransaction (Workspaces.reserveWorkspaceTx storage (WorkspaceRequest child (Just (sessionIdFor session, message.assignmentId)) root old old (fixtureRevision 0)) repository))
  allocateWorkspace storage binding Reserved >>= (@?= Right ())
  run env (runTransaction (Workspaces.markWorkspaceReadyTx binding)) >>= (@?= Right ())
  let version = ObjectiveVersion (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 0) old True root (addUTCTime 3600 now)
  intent <-
    if transferring
      then snd <$> (right =<< run env (Sessions.requestTransfer access (fixtureRevision 2) (fixtureRevision 0) (fixtureOperationId "transfer") version binding.workspace (fixtureAgentName "successor") successor))
      else pure (TransferIntent 1 (sessionIdFor session) session.objective actor (fixtureOperationId "not-requested") version old successor (fixtureAgentName "successor") (fixtureRevision 0) (fixtureRevision 1) root binding.workspace)
  stopped <- newIORef 0
  let backend = SupervisorBackend (pure (Right boot)) (\_ _ _ -> fail "transfer cannot capture") (\_ _ _ _ _ -> fail "transfer cannot launch") (const (pure (Right True))) (\_ -> modifyIORef' stopped (+ 1) >> pure (Right ()))
      runtime = SupervisorRuntime env allowAllActionAuthorizerForTests (const (pure (Right ()))) (const (pure (Right ()))) (\_ _ _ -> fail "transfer cannot select new commands") backend
  callback env binding intent runtime stopped

reserveProcess :: AppEnv -> WorkspaceBinding -> IO ProcessRecord
reserveProcess env binding = do
  now <- getCurrentTime
  let digest = "sha256:" <> Text.replicate 64 "a"
      operation = fixtureOperationId "retained-process"
      command = ProcessCommand "validate" digest "/bin/validate" [] "" Map.empty 30 1024
      record = ProcessRecord operation (fixtureAttemptId "original-process-actual") (fixtureOwner "actual-owner") (fixtureGeneration 1) (workspaceBindingDigest binding) digest digest command (addUTCTime 30 now) (processUnit operation digest) Nothing Nothing ProcessReserved Nothing Nothing
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

-- The objective receipt exercises the existing consumer contract only. Native
-- workspace qualification must not claim this as IR-13 provider evidence.
establishSuccessor :: AppEnv -> WorkspaceBinding -> TransferIntent -> FenceProof -> IO Text
establishSuccessor env binding intent proof = do
  access <- right =<< run env (Sessions.authorizeSession intent.sessionId intent.actor (pure (Right ())))
  let current = do
        Just (state, _) <- right =<< run env (Sessions.inspectSession intent.sessionId)
        pure state
  state <- current
  _ <- right =<< run env (Sessions.retainTransferFence access state.revision (fixtureRevision 0) (fixtureOperationId "retain-fence") intent.operationId (FencedAndSettled proof))
  Just (_, original) <- pure binding.request.assignment
  pending <- current
  _ <- right =<< run env (Sessions.recordResult access pending.revision (fixtureRevision 0) (fixtureOperationId "finish-original") (AssignmentResult 1 original AssignmentFailed Nothing Aeson.Null []))
  ready <- current
  let receipt = OwnershipReceipt 1 intent.objective intent.operationId (ownershipFingerprint intent proof) (advanceRevision intent.expected.revision)
  _ <- right =<< run env (Sessions.establishOwner access ready.revision (fixtureRevision 0) (fixtureOperationId "establish") intent.operationId proof receipt)
  established <- current
  (_, message) <- right =<< run env (Sessions.acceptMessage access established.revision (fixtureRevision 1) (fixtureOperationId "successor-message") (Instruction 1 FollowUp (fixtureInstruction "continue fixture") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing))
  (_, started) <- right =<< run env (Sessions.startAssignment access (advanceRevision established.revision) (fixtureRevision 1) (fixtureOperationId "successor-start") message.assignmentId)
  maybe (fail "missing actual successor child") pure started.childWorkflowId

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureInstruction :: Text -> InstructionText
fixtureInstruction value = either (error . show) id (parseInstructionText value)

fixtureLimit :: (SessionLimit a) => Integer -> a
fixtureLimit value = either (error . show) id (parseSessionLimit value)

fixtureGeneration :: Integer -> Generation.StateRevision "execution-attempt"
fixtureGeneration value = either (error . show) id (Generation.parseRevision value)

fixtureOwner :: ClaimText.Text -> Claim.ClaimOwner
fixtureOwner value = either (error . show) id (Claim.parseClaimOwner value)

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureDelegationDepth :: Int -> DelegationDepth
fixtureDelegationDepth = either (error . show) id . parseDelegationDepth . toInteger
