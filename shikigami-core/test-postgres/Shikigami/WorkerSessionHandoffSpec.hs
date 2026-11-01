module Shikigami.WorkerSessionHandoffSpec (tests) where

import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Effectful (Eff)
import Keiro.Workflow (WorkflowOutcome (Completed, ContinuedAsNew, Suspended), runWorkflowWith)
import Keiro.Workflow.Child (runChildWorkflow)
import Keiro.Workflow.Types (WorkflowId (..))
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity, compatibilityIdentity)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Behavior.Run (newBehaviorEnv)
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Execution.Resources (Admission (..), Cancellation (..), Root (..))
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Transcript (ExecutionId (..), executionIdentity)
import Shikigami.Fixture.ExecutionIdentity (fixtureOperationId)
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude
import Shikigami.RouterWorkflowSpec qualified as Fixture
import Shikigami.StateRevision (StateRevision, advanceRevision, parseRevision)
import Shikigami.WorkerSession.Checkpoint qualified as Checkpoint
import Shikigami.WorkerSession.Handoff qualified as Handoff
import Shikigami.WorkerSession.Identity (assignmentChildWorkflowIdV2, sessionWorkflowId, sessionWorkflowName)
import Shikigami.WorkerSession.Input (InstructionText, parseInstructionText)
import Shikigami.WorkerSession.Input qualified as WorkerInput
import Shikigami.WorkerSession.Store qualified as Store
import Shikigami.WorkerSession.Transfer
import Shikigami.WorkerSession.Types
import Shikigami.WorkerSession.Workflow qualified as Session
import Shikigami.WorkerSessionStoreSpec (checkpointVersion, withConfiguredFixture)
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "WorkerSessionHandoff"
    [ testCase "unknown old effects and lost ownership acknowledgements never admit simultaneous writers" $
        withTransferFixture fixture True \env admission access owner -> do
          old <- expectRight =<< run env (Store.authorizeSession (sessionIdFor admission) admission.identity (pure (Right ())))
          intent <- expectRight =<< request env admission owner
          run env (Handoff.resumeHandoff owner.services intent.sessionId) >>= (@?= Right Handoff.HandoffPending)
          pending <- current env admission
          pending.phase @?= Transferring
          pending.epoch @?= (fixtureRevision 0)
          ((.stage) <$> pending.handoff) @?= Just TransferUnresolved
          refusedWrite owner admission admission.identity 0
          refusedWrite owner admission successor 1
          readIORef owner.ownershipUpdates >>= (@?= 0)
          writeIORef owner.inFlight False
          -- The external checkpoint commits, then loses its acknowledgement.
          run env (Handoff.resumeHandoff owner.services intent.sessionId) >>= (@?= Right Handoff.HandoffPending)
          actual <- current env admission
          actual.owner @?= admission.identity
          actual.epoch @?= (fixtureRevision 0)
          refusedWrite owner admission successor 1
          version <- owner.checkpoints.current admission.objective >>= expectRight
          version.owner @?= successor
          version.ownerEpoch @?= (fixtureRevision 1)
          let restarted = Handoff.TransferServices owner.services.sessions (Just owner.workspace) (Just owner.ownership)
          run env (Handoff.resumeHandoff restarted intent.sessionId) >>= (@?= Right (Handoff.HandoffEstablished successor (fixtureRevision 1)))
          run env (Handoff.resumeHandoff restarted intent.sessionId) >>= (@?= Right (Handoff.HandoffEstablished successor (fixtureRevision 1)))
          established <- current env admission
          established.phase @?= Idle
          established.epoch @?= (fixtureRevision 1)
          established.worker @?= Just (fixtureAgentName "successor")
          run env (Store.loadAdmission old) >>= (@?= Left SessionOwnerRefused)
          run env (Store.acceptMessage access established.revision (fixtureRevision 0) (fixtureOperationId "stale-epoch") (instruction 2)) >>= (@?= Left SessionOwnerRefused)
          owner.workspace.admitWrite workspaceRef intent.sessionId admission.identity (fixtureRevision 0) (fixtureOperationId "late-old") >>= assertLeft
          owner.workspace.admitWrite workspaceRef intent.sessionId successor (fixtureRevision 1) (fixtureOperationId "successor-write") >>= (@?= Right ())
          owner.workspace.admitWrite workspaceRef intent.sessionId successor (fixtureRevision 1) (fixtureOperationId "successor-write") >>= (@?= Right ())
          readIORef owner.writes >>= (@?= [fixtureOperationId "successor-write"])
          readIORef owner.ownershipUpdates >>= (@?= 1)
          request env admission owner >>= (@?= Right intent)
          run env (Handoff.requestHandoff owner.services intent.sessionId (fixtureRevision 0) (fixtureRevision 0) (fixtureOperationId "transfer") workspaceRef (fixtureAgentName "worker")) >>= (@?= Left MessageConflict)
          -- A stale checkpoint cannot restore the previous owner.
          stale <- checkpointVersion admission
          let obsolete = Checkpoint.CheckpointIntent V1 intent.sessionId admission.objective (fixtureOperationId "stale-checkpoint") admission.context.identity (fixtureRevision 0) stale (fixtureRevision 0) (fixtureRevision 1) []
          owner.checkpoints.commit obsolete >>= (@?= Checkpoint.CheckpointConflict)
          latest <- owner.checkpoints.current admission.objective >>= expectRight
          latest.owner @?= successor
          (_, follow) <- expectRight =<< run env (Store.acceptMessage access established.revision (fixtureRevision 1) (fixtureOperationId "new-assignment") (instruction 2))
          (_, started) <- expectRight =<< run env (Store.startAssignment access (advanceRevision established.revision) (fixtureRevision 1) (fixtureOperationId "new-start") follow.assignmentId)
          started.childWorkflowId @?= Just (assignmentChildWorkflowIdV2 intent.sessionId (fixtureAgentName "successor") follow.assignmentId),
      testCase "a fenced workspace cannot establish ownership while an accepted assignment remains active" $
        withTransferFixture fixture False \env admission access owner -> do
          (_, message) <- expectRight =<< run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (fixtureOperationId "send") (instruction 1))
          _ <- expectRight =<< run env (Store.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (fixtureOperationId "start") message.assignmentId)
          before <- current env admission
          _ <- expectRight =<< requestAt env admission owner before.revision
          writeIORef owner.inFlight False
          run env (Handoff.resumeHandoff owner.services (sessionIdFor admission)) >>= (@?= Right Handoff.HandoffPending)
          readIORef owner.ownershipUpdates >>= (@?= 0)
          pending <- current env admission
          (_, receipt) <- expectRight =<< run env (Store.recordResult access pending.revision (fixtureRevision 0) (fixtureOperationId "finish") (AssignmentResult V1 message.assignmentId AssignmentSucceeded Nothing (Aeson.String "retained artifact") [artifactReference "artifact-1"]))
          after <- current env admission
          after.phase @?= Transferring
          after.activeAssignment @?= Nothing
          run env (Handoff.resumeHandoff owner.services (sessionIdFor admission)) >>= (@?= Right (Handoff.HandoffEstablished successor (fixtureRevision 1)))
          reader <- expectRight =<< run env (Store.authorizeSession (sessionIdFor admission) successor (pure (Right ())))
          result <- expectRight =<< run env (Store.readResult reader message.assignmentId)
          ((.cursor) . fst <$> result) @?= Just receipt.cursor,
      testCase "a result committed before handoff replays its old acknowledgement after the owner changes" $
        withTransferFixture fixture False \env admission access owner -> do
          behavior <- newBehaviorEnv
          let runtime = owner.services.sessions
              session = sessionIdFor admission
              options = shikigamiWorkflowRunOptions env
              dependencies = Fixture.routerDeps env behavior (Routing.RoutingRuntime (\_ -> fail "unexpected routing") (\_ _ _ -> fail "unexpected routing")) runtime.agents
              drive = run env (runWorkflowWith options sessionWorkflowName (sessionWorkflowId session) (Session.sessionWorkflow runtime (Just (Session.WorkerSessionStart session))))
          (_, message) <- expectRight =<< run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (fixtureOperationId "send") (instruction 1))
          drive >>= (@?= Suspended)
          started <- expectRight =<< run env (Store.readAssignment access message.assignmentId)
          child <- maybe (assertFailure "missing mapping" >> fail "missing mapping") pure started.childWorkflowId
          completed <- run env (runChildWorkflow options Agent.agentRunWorkflowName child (Agent.agentRunWorkflow dependencies Nothing))
          output <- case completed of Completed (Right result) -> pure result.behaviorOutput; _ -> assertFailure (show completed) >> fail "child failed"
          pending <- current env admission
          -- Simulate the store commit succeeding just before the parent step's
          -- journal acknowledgement is lost.
          _ <- expectRight =<< run env (Store.recordResult access pending.revision (fixtureRevision 0) (fixtureOperationId ("result:" <> message.assignmentId.value)) (AssignmentResult V1 message.assignmentId AssignmentSucceeded Nothing output []))
          recorded <- current env admission
          _ <- expectRight =<< requestAt env admission owner recorded.revision
          writeIORef owner.inFlight False
          run env (Handoff.resumeHandoff owner.services session) >>= (@?= Right (Handoff.HandoffEstablished successor (fixtureRevision 1)))
          drive >>= (@?= ContinuedAsNew)
          final <- current env admission
          final.owner @?= successor
          final.epoch @?= (fixtureRevision 1)
          events <- expectRight =<< run env (Store.readEvents access (fixtureRevision 0) 100)
          length [() | EventReceipt {event = ResultAvailable {}} <- events] @?= 1,
      testCase "missing execution evidence keeps a settled workspace handoff unresolved" $
        withTransferFixture fixture False \env admission access owner -> do
          (_, message) <- expectRight =<< run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (fixtureOperationId "send") (instruction 1))
          _ <- expectRight =<< run env (Store.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (fixtureOperationId "start") message.assignmentId)
          _ <- expectRight =<< run env (Store.recordResult access (fixtureRevision 2) (fixtureRevision 0) (fixtureOperationId "finish") (AssignmentResult V1 message.assignmentId AssignmentSucceeded (Just (executionIdentity "unavailable-execution")) Aeson.Null []))
          _ <- expectRight =<< requestAt env admission owner (fixtureRevision 3)
          writeIORef owner.inFlight False
          run env (Handoff.resumeHandoff owner.services (sessionIdFor admission)) >>= (@?= Right Handoff.HandoffPending)
          readIORef owner.ownershipUpdates >>= (@?= 0)
          state <- current env admission
          state.epoch @?= (fixtureRevision 0),
      testCase "fence proof substitution refuses without advancing ownership" $
        withTransferFixture fixture False \env admission access owner -> do
          intent <- expectRight =<< request env admission owner
          let proof = FenceProof V1 (workspaceRef & #resource .~ "another-resource") intent.operationId (transferFingerprint intent) (fixtureRevision 0) (fixtureRevision 1) (fixtureProviderReceipt "foreign-proof")
          run env (Store.retainTransferFence access (fixtureRevision 1) (fixtureRevision 0) (fixtureOperationId "foreign-proof") intent.operationId (FencedAndSettled proof)) >>= (@?= Left SessionBindingConflict)
          state <- current env admission
          state.epoch @?= (fixtureRevision 0)
          state.revision @?= (fixtureRevision 1)
          readIORef owner.ownershipUpdates >>= (@?= 0),
      testCase "accepted ownership facts converge after root cancellation without granting new work" $
        withTransferFixture fixture True \env admission access owner -> do
          _ <- expectRight =<< request env admission owner
          writeIORef owner.inFlight False
          run env (Handoff.resumeHandoff owner.services (sessionIdFor admission)) >>= (@?= Right Handoff.HandoffPending)
          rootId <- maybe (assertFailure "missing root" >> fail "missing root") pure admission.context.executionRootId
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          run env (Roots.setRootControl rootId root.revision StopWork Nothing) >>= (@?= Right ())
          run env (Handoff.resumeHandoff owner.services (sessionIdFor admission)) >>= (@?= Right (Handoff.HandoffEstablished successor (fixtureRevision 1)))
          state <- current env admission
          run env (Store.acceptMessage access state.revision (fixtureRevision 1) (fixtureOperationId "cancelled-root-work") (instruction 2)) >>= (@?= Left SessionOwnerRefused),
      testCase "absent real adapters refuse before a transfer request changes state" $
        withTransferFixture fixture False \env admission _ owner -> do
          let unavailable = owner.services & #workspaces .~ Nothing
          run env (Handoff.requestHandoff unavailable (sessionIdFor admission) (fixtureRevision 0) (fixtureRevision 0) (fixtureOperationId "transfer") workspaceRef (fixtureAgentName "successor")) >>= assertLeft
          state <- current env admission
          state.revision @?= (fixtureRevision 0)
          state.handoff @?= Nothing
    ]

data Owners = Owners
  { services :: !(Handoff.TransferServices),
    workspace :: !(WorkspaceProvider),
    ownership :: !(OwnershipProvider),
    checkpoints :: !(Checkpoint.CheckpointProvider),
    inFlight :: !(IORef Bool),
    writes :: !(IORef [OperationId]),
    ownershipUpdates :: !(IORef Int)
  }

workspaceRef :: WorkspaceRef
workspaceRef = WorkspaceRef "fixture-workspace-owner" "retained-workspace"

successor :: AgentIdentity
successor = compatibilityIdentity (fixtureAgentName "successor")

instruction :: Integer -> Instruction
instruction revision = Instruction V1 FollowUp (fixtureInstruction "retained assignment") (fixtureRevision revision) (fixtureRevision 1) (fixtureRevision 1) Nothing

request :: AppEnv -> SessionAdmission -> Owners -> IO (Either SessionError TransferIntent)
request env admission owners = requestAt env admission owners (fixtureRevision 0)

requestAt :: AppEnv -> SessionAdmission -> Owners -> StateRevision "worker-session" -> IO (Either SessionError TransferIntent)
requestAt env admission owners revision = run env (Handoff.requestHandoff owners.services (sessionIdFor admission) revision (fixtureRevision 0) (fixtureOperationId "transfer") workspaceRef (fixtureAgentName "successor"))

refusedWrite :: Owners -> SessionAdmission -> AgentIdentity -> Integer -> IO ()
refusedWrite owner admission actor epoch = owner.workspace.admitWrite workspaceRef (sessionIdFor admission) actor (fixtureRevision epoch) (fixtureOperationId "refused") >>= assertLeft

withTransferFixture :: DatabaseFixture -> Bool -> (AppEnv -> SessionAdmission -> Store.SessionAccess -> Owners -> IO a) -> IO a
withTransferFixture fixture loseAcknowledgement callback = withConfiguredFixture fixture (\admission -> admission & #delegator . #delegates .~ map fixtureAgentName ["worker", "successor"]) \env admission access -> do
  initial <- checkpointVersion admission
  objective <- newIORef (initial, Map.empty)
  inFlight <- newIORef True
  fence <- newIORef Nothing
  writes <- newIORef []
  ownershipUpdates <- newIORef 0
  let reconcile intent = do
        original <- readIORef fence
        if maybe False (/= intent) original
          then pure FenceConflict
          else do
            writeIORef fence (Just intent)
            pending <- readIORef inFlight
            pure (if pending then FenceUnresolved else FencedAndSettled (FenceProof V1 intent.workspace intent.operationId (transferFingerprint intent) intent.oldEpoch intent.newEpoch (fixtureProviderReceipt "fixture-settled-proof")))
      admitWrite resource session actor epoch operation = do
        stored <- run env (Store.inspectSession session) >>= expectRight
        intent <- readIORef fence
        pending <- readIORef inFlight
        case (stored, intent) of
          (Just (state, _), Just transfer) | resource == workspaceRef && transfer.sessionId == session && not pending && state.phase `elem` [Idle, Active] && state.owner == actor && state.epoch == epoch && epoch == transfer.newEpoch -> do
            atomicModifyIORef' writes (\accepted -> (if operation `elem` accepted then accepted else accepted <> [operation], ()))
            pure (Right ())
          _ -> pure (Left "conditional session/workspace owner refused")
      ownership = OwnershipProvider \intent proof -> do
        (outcome, changed) <- atomicModifyIORef' objective \stored@(version, receipts) ->
          case Map.lookup intent.operationId receipts of
            Just (original, receipt) | original == ownershipFingerprint intent proof -> (stored, (OwnershipAccepted receipt, False))
            Just _ -> (stored, (OwnershipConflict, False))
            Nothing | version /= intent.expected || not (matchesFence intent proof) -> (stored, (OwnershipConflict, False))
            Nothing ->
              let receipt = OwnershipReceipt V1 intent.objective intent.operationId (ownershipFingerprint intent proof) (advanceRevision version.revision)
                  next = version & #revision .~ (advanceRevision version.revision) & #owner .~ intent.newOwner & #ownerEpoch .~ intent.newEpoch
               in ((next, Map.insert intent.operationId (receipt.fingerprint, receipt) receipts), (OwnershipAccepted receipt, True))
        case outcome of
          OwnershipAccepted _ -> do
            when changed (modifyIORef' ownershipUpdates (+ 1))
            pure (if loseAcknowledgement && changed then OwnershipUnresolved else outcome)
          _ -> pure outcome
      checkpoints =
        Checkpoint.CheckpointProvider
          (\_ -> Right . fst <$> readIORef objective)
          ( \intent -> do
              (version, _) <- readIORef objective
              pure (if intent.expected /= version then Checkpoint.CheckpointConflict else Checkpoint.CheckpointUnavailable)
          )
      workspace = WorkspaceProvider reconcile admitWrite
      runtime = Session.SessionRuntime env [Fixture.successSpecialist "worker", Fixture.successSpecialist "successor"] disabledDirectoryHandle (const (pure (Right ()))) (Just checkpoints)
  callback env admission access (Owners (Handoff.TransferServices runtime (Just workspace) (Just ownership)) workspace ownership checkpoints inFlight writes ownershipUpdates)

current :: AppEnv -> SessionAdmission -> IO SessionState
current env admission = do
  Just (state, _) <- expectRight =<< run env (Store.inspectSession (sessionIdFor admission))
  pure state

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= either (assertFailure . show) pure

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> fail (show err)) pure

assertLeft :: (Show a, Show b) => Either a b -> IO ()
assertLeft = \case Left _ -> pure (); Right value -> assertFailure ("unexpected acceptance: " <> show value)

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureInstruction :: Text -> InstructionText
fixtureInstruction value = either (error . show) id (parseInstructionText value)

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureProviderReceipt :: Text -> WorkerInput.ProviderReceipt
fixtureProviderReceipt = either (error . show) id . WorkerInput.parseProviderReceipt
